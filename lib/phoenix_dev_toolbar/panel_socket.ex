defmodule PhoenixDevToolbar.PanelSocket do
  @moduledoc false
  # The panel's own LiveView socket (ADR 04), at `<path>/live/websocket`,
  # upgraded by PhoenixDevToolbar.Plug itself: no host socket, so no host CSRF
  # token and no host session.
  #
  # The origin rule is ours, not the host's: the panel iframe is always same
  # origin with the page, so a socket request must carry an `Origin` that names
  # the host it was sent to (see `same_origin?/1`). The host socket's and the
  # endpoint's `check_origin` (usually `false` in generated dev configs) play no
  # part.
  #
  # It does what Phoenix's WebSocket transport does, through the public custom
  # transport API (`Phoenix.Socket.Transport.connect_info/3`), then the host's LiveView socket handler (`connect/1`) and
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
  # The host socket's `websocket:` options `timeout` and `max_frame_size` are
  # passed through; its `check_origin` is not.

  @behaviour WebSock

  require Logger

  alias Phoenix.Socket.Transport
  alias PhoenixDevToolbar.OriginCheck
  alias PhoenixDevToolbar.PanelSocket
  alias PhoenixDevToolbar.Store

  # Phoenix's WebSocket defaults (Phoenix.Transports.WebSocket.default_config/0).
  @serializers [
    {Phoenix.Socket.V1.JSONSerializer, "~> 1.0.0"},
    {Phoenix.Socket.V2.JSONSerializer, "~> 2.0.0"}
  ]
  @defaults [serializer: @serializers, timeout: 60_000, compress: false]
  @host_options [:timeout, :max_frame_size]

  @connect_info [:peer_data, :uri, :user_agent, :x_headers]

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
        |> check_origin()
        |> connect(endpoint, handler, options)
        |> Plug.Conn.halt()
    end
  end

  # Without an endpoint (the plug used outside Phoenix) there is nothing to join.
  def upgrade(conn), do: conn |> Plug.Conn.send_resp(404, "") |> Plug.Conn.halt()

  # A browser always sends `Origin` on a WebSocket handshake, and for the panel
  # iframe it is the page's own origin. Refuse a missing or foreign one.
  #
  # The scheme must be http or https but is not compared with the request's: a
  # TLS terminating proxy or tunnel makes `conn.scheme` differ from the
  # browser's. The host must match exactly (case-insensitively). The port is
  # compared when the `Host` header names one (otherwise the Origin must use a
  # default port), so another local app on a different port is refused too.
  #
  # Behind a proxy or tunnel that rewrites the Host header the browser's Origin
  # names a host the server never sees: `allowed_origins:` lists those origins,
  # matched exactly (scheme, host, port), whatever the Host header says.
  defp check_origin(conn) do
    case OriginCheck.same_origin?(conn) or OriginCheck.allowed_origin?(conn) do
      true ->
        conn

      false ->
        log_refused(conn)
        conn |> Plug.Conn.send_resp(403, "") |> Plug.Conn.halt()
    end
  end

  @logged {PhoenixDevToolbar.PanelSocket, :logged_refusals}
  # Distinct {origin, host} pairs named in the log, at most (a page can send any).
  @max_logged 10

  # Once per distinct pair, for the first @max_logged of a boot (mirrors
  # `HostCheck.log_refused/1`). Values are inspected with limits: they come
  # from the client.
  defp log_refused(conn) do
    pair = {header_for_log(conn, "origin"), header_for_log(conn, "host")}
    logged = :persistent_term.get(@logged, [])

    case pair in logged or length(logged) >= @max_logged do
      true ->
        :ok

      false ->
        :persistent_term.put(@logged, [pair | logged])
        {origin, host} = pair

        Logger.warning(
          "[phoenix_dev_toolbar] refused a panel socket request: Origin #{origin} does not " <>
            "match Host #{host}. Behind a proxy or tunnel that rewrites the Host header, add " <>
            "the page's origin to `allowed_origins:` in the toolbar config"
        )
    end
  end

  defp header_for_log(conn, name) do
    conn
    |> Plug.Conn.get_req_header(name)
    |> inspect(limit: 5, printable_limit: 200)
  end

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
      WebSockAdapter.upgrade(conn, PanelSocket, wrapped, options)
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

  # `__sockets__/0` is generated by `Phoenix.Endpoint` (1.8): an endpoint
  # without it (not a Phoenix endpoint) mounts nothing we can join.
  defp mounted_sockets(endpoint) do
    for {_path, module, opts} <- endpoint.__sockets__(), do: {module, opts}
  rescue
    UndefinedFunctionError -> []
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

  @doc false
  # Forgets the logged refusals, so a test sees the first one of each pair again.
  @spec reset_logged_refusals() :: :ok
  def reset_logged_refusals do
    _ = :persistent_term.erase(@logged)
    :ok
  end

  defp log_once(endpoint) do
    key = {PanelSocket, :no_live_socket, endpoint}

    case :persistent_term.get(key, false) do
      true ->
        :ok

      false ->
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
