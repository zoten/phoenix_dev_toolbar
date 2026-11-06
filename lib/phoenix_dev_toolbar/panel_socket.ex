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
  # as a WebSock and decodes every frame: only joins of panel LiveViews go
  # through, `lv:<id>` where the panel's dead render registered `id`
  # (`Store.allow_panel/1`; LiveView verifies that the topic is the id signed in
  # the session token). An `lv:` join for an unknown id (a host LiveView, or a
  # panel the Store forgot after a restart) gets LiveView's own `stale` reply, so
  # an open panel reloads and registers again; anything else closes the
  # connection.
  #
  # The host socket's `websocket:` options that Phoenix reads here
  # (`check_origin`, `timeout`, `max_frame_size`) are passed through: our
  # `check_origin` is the host socket's, and on Phoenix releases that cache it
  # per handler only, both entries cache the same value.

  @behaviour WebSock

  require Logger

  alias Phoenix.Socket.Transport
  alias PhoenixDevToolbar.Store

  # Phoenix's WebSocket defaults (Phoenix.Transports.WebSocket.default_config/0).
  @serializers [
    {Phoenix.Socket.V1.JSONSerializer, "~> 1.0.0"},
    {Phoenix.Socket.V2.JSONSerializer, "~> 2.0.0"}
  ]
  @defaults [serializer: @serializers, timeout: 60_000, compress: false]
  @host_options [:check_origin, :timeout, :max_frame_size]

  @connect_info [:peer_data, :uri, :user_agent]

  @doc "Upgrades `conn` to the panel's LiveView socket, or answers 403, 404 or 400."
  @spec upgrade(Plug.Conn.t()) :: Plug.Conn.t()
  def upgrade(%Plug.Conn{private: %{phoenix_endpoint: endpoint}} = conn) do
    case handler(endpoint) do
      nil ->
        log_once(endpoint)
        conn |> Plug.Conn.send_resp(404, "") |> Plug.Conn.halt()

      {handler, options} ->
        conn
        |> Plug.Conn.fetch_query_params()
        |> Transport.check_origin(handler, endpoint, options)
        |> connect(endpoint, handler, options)
        |> Plug.Conn.halt()
    end
  end

  # Without an endpoint (the plug used outside Phoenix) there is nothing to join.
  def upgrade(conn), do: conn |> Plug.Conn.send_resp(404, "") |> Plug.Conn.halt()

  defp connect(%Plug.Conn{halted: true} = conn, _endpoint, _handler, _options), do: conn

  defp connect(conn, endpoint, handler, options) do
    config = %{
      endpoint: endpoint,
      transport: :websocket,
      options: options,
      params: conn.params,
      connect_info: Transport.connect_info(conn, endpoint, @connect_info)
    }

    with {:ok, serializer} <- serializer(conn.params["vsn"]),
         {:ok, state} <- handler.connect(config) do
      wrapped = %{handler: handler, state: state, serializer: serializer}
      WebSockAdapter.upgrade(conn, __MODULE__, wrapped, options)
    else
      _error -> Plug.Conn.send_resp(conn, 403, "")
    end
  rescue
    error in WebSockAdapter.UpgradeError -> Plug.Conn.send_resp(conn, 400, error.message)
  end

  # The serializer Phoenix negotiates for `vsn` (Phoenix.Socket), for our replies.
  defp serializer(vsn) do
    with {:ok, version} <- Version.parse(vsn || "1.0.0"),
         {serializer, _requirement} <-
           Enum.find(@serializers, fn {_serializer, req} -> Version.match?(version, req) end) do
      {:ok, serializer}
    else
      _error -> :error
    end
  end

  # The endpoint's LiveView socket and its options: Phoenix.LiveView.Socket, or
  # the host's own module that uses it (its `lv:*` topics go to
  # Phoenix.LiveView.Channel). It must be mounted in the endpoint: its
  # supervision tree runs the channels.
  defp handler(endpoint) do
    sockets = mounted_sockets(endpoint)

    [Phoenix.LiveView.Socket | Enum.map(sockets, &elem(&1, 0))]
    |> Enum.uniq()
    |> Enum.find(&(live_socket?(&1) and endpoint.config({:socket, &1}) != nil))
    |> case do
      nil -> nil
      handler -> {handler, options(sockets, handler)}
    end
  end

  defp mounted_sockets(endpoint) do
    for {_path, module, opts} <- endpoint.__sockets__(), do: {module, opts}
  rescue
    _error -> []
  end

  defp options(sockets, handler) do
    host =
      case List.keyfind(sockets, handler, 0) do
        {_handler, opts} -> websocket_options(opts)
        nil -> []
      end

    Keyword.merge(@defaults, Keyword.take(host, @host_options))
  end

  defp websocket_options(opts) when is_list(opts) do
    case Keyword.get(opts, :websocket) do
      websocket when is_list(websocket) -> websocket
      _true_or_false -> []
    end
  end

  defp websocket_options(_opts), do: []

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
  def init(%{handler: handler, state: state} = wrapped),
    do: wrap(wrapped, handler.init(state))

  @impl WebSock
  def handle_in({text, opts} = frame, %{handler: handler, state: state} = wrapped) do
    case check(Keyword.get(opts, :opcode), text) do
      :ok -> wrap(wrapped, handler.handle_in(frame, state))
      {:stale, reply} -> {:push, {:text, encode(wrapped.serializer, reply)}, wrapped}
      :close -> {:stop, :normal, wrapped}
    end
  end

  @impl WebSock
  def handle_info(message, %{handler: handler, state: state} = wrapped),
    do: wrap(wrapped, handler.handle_info(message, state))

  @impl WebSock
  def terminate(reason, %{handler: handler, state: state}), do: handler.terminate(reason, state)

  # The handler's own state is the last element of every WebSock result.
  defp wrap(wrapped, result) when is_tuple(result) do
    last = tuple_size(result) - 1
    put_elem(result, last, %{wrapped | state: elem(result, last)})
  end

  # Every text frame is decoded (an escaped "phx\u005fjoin" is a join too). A
  # join must be for a registered panel; uploads (lvu:) are refused, the panel
  # has none. Binary frames are refused: the panel sends none.
  defp check(:text, text) do
    case Phoenix.json_library().decode(text) do
      {:ok, [join_ref, ref, topic, "phx_join", _payload]} -> join(topic, join_ref, ref)
      {:ok, %{"topic" => topic, "event" => "phx_join"} = msg} -> join(topic, nil, msg["ref"])
      {:ok, [_join_ref, _ref, _topic, event, _payload]} when is_binary(event) -> :ok
      {:ok, %{"event" => event}} when is_binary(event) -> :ok
      _other -> :close
    end
  end

  defp check(_binary, _data), do: :close

  defp join("phoenix", _join_ref, _ref), do: :ok

  defp join("lv:" <> id = topic, join_ref, ref) when is_binary(id) do
    case Store.panel_allowed?(id) do
      true ->
        :ok

      false ->
        {:stale,
         %Phoenix.Socket.Reply{
           topic: topic,
           join_ref: join_ref,
           ref: ref,
           status: :error,
           payload: %{reason: "stale"}
         }}
    end
  end

  defp join(_topic, _join_ref, _ref), do: :close

  defp encode(serializer, reply) do
    {:socket_push, :text, data} = serializer.encode!(reply)
    data
  end
end
