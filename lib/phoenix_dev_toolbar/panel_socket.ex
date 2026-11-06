defmodule PhoenixDevToolbar.PanelSocket do
  @moduledoc false
  # The panel's own LiveView socket (ADR 04), at `<path>/live/websocket`,
  # upgraded by PhoenixDevToolbar.Plug itself: no host socket, so no host CSRF
  # token and no host session. Joining the panel still needs its signed LiveView
  # session token, which only the panel's HTML holds (same origin), and the
  # endpoint's `check_origin` applies.
  #
  # It does what Phoenix's WebSocket transport does, through the public custom
  # transport API (`Phoenix.Socket.Transport.check_origin/4`, `connect_info/3`),
  # then `Phoenix.LiveView.Socket.connect/1` and `WebSockAdapter.upgrade/4`. The
  # host endpoint is used, so PubSub, the secret key base and LiveView's
  # session verification are the host's. `connect_info` carries no session:
  # LiveView then skips the CSRF and session checks, and the panel reads nothing
  # from the host session.

  alias Phoenix.Socket.Transport

  @handler Phoenix.LiveView.Socket

  # Phoenix's WebSocket defaults (Phoenix.Transports.WebSocket.default_config/0).
  @options [
    serializer: [
      {Phoenix.Socket.V1.JSONSerializer, "~> 1.0.0"},
      {Phoenix.Socket.V2.JSONSerializer, "~> 2.0.0"}
    ],
    timeout: 60_000,
    compress: false
  ]

  @connect_info [:peer_data, :uri, :user_agent]

  @doc "Upgrades `conn` to the panel's LiveView socket, or answers 403 or 400."
  @spec upgrade(Plug.Conn.t()) :: Plug.Conn.t()
  def upgrade(%Plug.Conn{private: %{phoenix_endpoint: endpoint}} = conn) do
    conn
    |> Plug.Conn.fetch_query_params()
    |> Transport.check_origin(@handler, endpoint, @options)
    |> connect(endpoint)
    |> Plug.Conn.halt()
  end

  # Without an endpoint (the plug used outside Phoenix) there is nothing to join.
  def upgrade(conn), do: conn |> Plug.Conn.send_resp(404, "") |> Plug.Conn.halt()

  defp connect(%Plug.Conn{halted: true} = conn, _endpoint), do: conn

  defp connect(conn, endpoint) do
    config = %{
      endpoint: endpoint,
      transport: :websocket,
      options: @options,
      params: conn.params,
      connect_info: Transport.connect_info(conn, endpoint, @connect_info)
    }

    case @handler.connect(config) do
      {:ok, state} -> WebSockAdapter.upgrade(conn, @handler, state, @options)
      _error -> Plug.Conn.send_resp(conn, 403, "")
    end
  rescue
    error in WebSockAdapter.UpgradeError -> Plug.Conn.send_resp(conn, 400, error.message)
  end
end
