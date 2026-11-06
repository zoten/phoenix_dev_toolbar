defmodule PhoenixDevToolbar.PanelSocket do
  @moduledoc false
  # The panel's own LiveView socket (ADR 04), at `<path>/live/websocket`,
  # upgraded by PhoenixDevToolbar.Plug itself: no host socket, so no host CSRF
  # token and no host session. The endpoint's `check_origin` applies.
  #
  # It does what Phoenix's WebSocket transport does, through the public custom
  # transport API (`Phoenix.Socket.Transport.check_origin/4`, `connect_info/3`),
  # then the host's LiveView socket handler (`connect/1`) and
  # `WebSockAdapter.upgrade/4`. Not done, as the panel needs none of it: code
  # reloading on connect, subprotocols, a pool drainer (connections close as the
  # endpoint stops). `connect_info` carries no session: LiveView then skips its
  # CSRF and session checks and the panel reads nothing from the host session.
  #
  # So that this never becomes a way into the host's own LiveViews (whose session
  # tokens would join here without those checks), this module wraps the handler
  # as a WebSock and only lets through joins of panel LiveViews: `lv:<id>` where
  # the panel's dead render registered `id` (`Store.allow_panel/1`; LiveView
  # verifies that the topic is the id signed in the session token). Anything
  # else closes the connection.

  @behaviour WebSock

  require Logger

  alias Phoenix.Socket.Transport
  alias PhoenixDevToolbar.Store

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

  @doc "Upgrades `conn` to the panel's LiveView socket, or answers 403, 404 or 400."
  @spec upgrade(Plug.Conn.t()) :: Plug.Conn.t()
  def upgrade(%Plug.Conn{private: %{phoenix_endpoint: endpoint}} = conn) do
    case handler(endpoint) do
      nil ->
        log_once(endpoint)
        conn |> Plug.Conn.send_resp(404, "") |> Plug.Conn.halt()

      handler ->
        conn
        |> Plug.Conn.fetch_query_params()
        |> Transport.check_origin(handler, endpoint, @options)
        |> connect(endpoint, handler)
        |> Plug.Conn.halt()
    end
  end

  # Without an endpoint (the plug used outside Phoenix) there is nothing to join.
  def upgrade(conn), do: conn |> Plug.Conn.send_resp(404, "") |> Plug.Conn.halt()

  defp connect(%Plug.Conn{halted: true} = conn, _endpoint, _handler), do: conn

  defp connect(conn, endpoint, handler) do
    config = %{
      endpoint: endpoint,
      transport: :websocket,
      options: @options,
      params: conn.params,
      connect_info: Transport.connect_info(conn, endpoint, @connect_info)
    }

    case handler.connect(config) do
      {:ok, state} -> WebSockAdapter.upgrade(conn, __MODULE__, {handler, state}, @options)
      _error -> Plug.Conn.send_resp(conn, 403, "")
    end
  rescue
    error in WebSockAdapter.UpgradeError -> Plug.Conn.send_resp(conn, 400, error.message)
  end

  # The endpoint's LiveView socket: Phoenix.LiveView.Socket, or the host's own
  # module that uses it (its `lv:*` topics go to Phoenix.LiveView.Channel). It
  # must be mounted in the endpoint: its supervision tree runs the channels.
  defp handler(endpoint) do
    [Phoenix.LiveView.Socket | mounted_sockets(endpoint)]
    |> Enum.uniq()
    |> Enum.find(&(live_socket?(&1) and endpoint.config({:socket, &1}) != nil))
  end

  defp mounted_sockets(endpoint) do
    for {_path, module, _opts} <- endpoint.__sockets__(), do: module
  rescue
    _error -> []
  end

  defp live_socket?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__channel__, 1) and
      match?({Phoenix.LiveView.Channel, _opts}, module.__channel__("lv:pdt"))
  end

  defp log_once(endpoint) do
    key = {__MODULE__, :no_live_socket, endpoint}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)

      Logger.warning(
        "[phoenix_dev_toolbar] the panel cannot connect: #{inspect(endpoint)} mounts no " <>
          "Phoenix.LiveView.Socket (socket \"/live\", Phoenix.LiveView.Socket)"
      )
    end
  end

  ## WebSock, around the LiveView socket handler

  @impl WebSock
  def init({handler, state}), do: wrap(handler, handler.init(state))

  @impl WebSock
  def handle_in({text, _opts} = frame, {handler, state}) do
    case allowed?(text) do
      true -> wrap(handler, handler.handle_in(frame, state))
      false -> {:stop, :normal, {handler, state}}
    end
  end

  @impl WebSock
  def handle_info(message, {handler, state}),
    do: wrap(handler, handler.handle_info(message, state))

  @impl WebSock
  def terminate(reason, {handler, state}), do: handler.terminate(reason, state)

  # The handler's own state is the last element of every WebSock result.
  defp wrap(handler, result) when is_tuple(result) do
    last = tuple_size(result) - 1
    put_elem(result, last, {handler, elem(result, last)})
  end

  # Only joins are checked: a frame without "phx_join" goes through untouched.
  # A join must be for a registered panel; uploads (lvu:) are refused, the
  # panel has none.
  defp allowed?(text) when is_binary(text) do
    case String.contains?(text, "phx_join") do
      false -> true
      true -> text |> join_topic() |> allowed_topic?()
    end
  end

  defp allowed?(_binary_frame), do: false

  defp join_topic(text) do
    case Phoenix.json_library().decode(text) do
      {:ok, [_join_ref, _ref, topic, "phx_join", _payload]} -> topic
      {:ok, %{"topic" => topic, "event" => "phx_join"}} -> topic
      {:ok, _other_event} -> :not_a_join
      {:error, _reason} -> nil
    end
  end

  defp allowed_topic?(:not_a_join), do: true
  defp allowed_topic?("phoenix"), do: true
  defp allowed_topic?("lv:" <> id), do: Store.panel_allowed?(id)
  defp allowed_topic?(_other), do: false
end
