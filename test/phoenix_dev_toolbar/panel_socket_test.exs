defmodule PhoenixDevToolbar.PanelSocketTest do
  # The panel's own LiveView socket (ADR 04), end to end: a real Bandit server,
  # a real WebSocket, the panel LiveView joined with no session cookie and no
  # CSRF token (what made the host socket refuse it on pages without one).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import PhoenixDevToolbar.PageHelpers

  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.WebSocketClient

  @endpoint DemoWeb.Endpoint

  setup do
    Store.reset()
    attach_plugins()
    on_exit(fn -> Store.reset() end)

    server = start_supervised!({Bandit, plug: DemoWeb.Endpoint, port: 0, ip: :loopback})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{port: port}
  end

  # A page's sid, then the panel's LiveView join params from its dead render.
  defp panel_join_params do
    {_conn, sid} = load_page("/demo")

    main =
      build_conn()
      |> get("/__pdt/panel?sid=#{sid}")
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-phx-session]")

    [id] = LazyHTML.attribute(main, "id")
    [session] = LazyHTML.attribute(main, "data-phx-session")
    static = main |> LazyHTML.attribute("data-phx-static") |> List.first()

    {id,
     %{
       "url" => "http://localhost/__pdt/panel?sid=#{sid}",
       "session" => session,
       "static" => static,
       "params" => %{"_mounts" => 0}
     }}
  end

  defp connect!(port, vsn \\ "2.0.0") do
    {:ok, socket} =
      WebSocketClient.connect(port, "/__pdt/live/websocket?vsn=#{vsn}", [
        {"Origin", "http://localhost:#{port}"}
      ])

    socket
  end

  defp host_main do
    build_conn()
    |> get("/demo")
    |> html_response(200)
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-phx-session]")
  end

  # A host LiveView's id and join params, from one dead render (LiveView checks
  # that the topic is the id signed in the token).
  defp host_join do
    main = host_main()

    {main |> LazyHTML.attribute("id") |> hd(),
     %{
       "url" => "http://localhost/demo",
       "session" => main |> LazyHTML.attribute("data-phx-session") |> hd(),
       "static" => main |> LazyHTML.attribute("data-phx-static") |> List.first(),
       "params" => %{}
     }}
  end

  # The panel pushes diffs once joined: skip them up to the reply to `ref`.
  defp recv_reply(socket, ref) do
    case WebSocketClient.recv_json(socket) do
      [_join_ref, ^ref, _topic, "phx_reply", _payload] = reply -> reply
      _push -> recv_reply(socket, ref)
    end
  end

  defp assert_stale(reply) do
    assert [_, _, "lv:" <> _, "phx_reply", %{"status" => "error", "response" => response}] =
             reply

    assert response == %{"reason" => "stale"}
  end

  test "the panel joins through its own socket with no cookie and no CSRF token", %{port: port} do
    {id, join} = panel_join_params()

    {:ok, socket} =
      WebSocketClient.connect(port, "/__pdt/live/websocket?vsn=2.0.0", [
        {"Origin", "http://localhost:#{port}"}
      ])

    :ok = WebSocketClient.send_json(socket, ["1", "1", "lv:#{id}", "phx_join", join])

    assert [
             "1",
             "1",
             "lv:" <> _,
             "phx_reply",
             %{"status" => "ok", "response" => %{"rendered" => _}}
           ] =
             WebSocketClient.recv_json(socket)
  end

  # The bug this socket fixes: the host's socket (connect_info with a session)
  # refuses the same join without a matching CSRF token, and LiveView then
  # sends the iframe to its own URL at once: a reload loop.
  test "the host's own socket refuses the same join (stale)", %{port: port} do
    {id, join} = panel_join_params()

    {:ok, socket} =
      WebSocketClient.connect(port, "/live/websocket?vsn=2.0.0", [
        {"Origin", "http://localhost:#{port}"}
      ])

    :ok = WebSocketClient.send_json(socket, ["1", "1", "lv:#{id}", "phx_join", join])

    assert [
             "1",
             "1",
             _topic,
             "phx_reply",
             %{"status" => "error", "response" => %{"reason" => "stale"}}
           ] =
             WebSocketClient.recv_json(socket)
  end

  # The panel socket must never become a way into the host's own LiveViews: a
  # host LiveView's session token would join here without the host's CSRF and
  # session checks. Only registered panels may join; any other LiveView gets
  # LiveView's own `stale` reply.
  test "a host LiveView cannot be joined through the panel socket", %{port: port} do
    {id, join} = host_join()
    socket = connect!(port)
    :ok = WebSocketClient.send_json(socket, ["1", "1", "lv:#{id}", "phx_join", join])
    assert_stale(WebSocketClient.recv_json(socket))
  end

  test "an escaped event name is still a join (decoded before the check)", %{port: port} do
    {id, join} = host_join()
    socket = connect!(port)
    escaped = ~s(["1","1","lv:#{id}","phx\\u005fjoin",) <> Jason.encode!(join) <> "]"

    :ok = WebSocketClient.send_frame(socket, escaped)
    assert_stale(WebSocketClient.recv_json(socket))
  end

  test "a second join on a panel's connection is checked too", %{port: port} do
    {id, join} = panel_join_params()
    socket = connect!(port)

    :ok = WebSocketClient.send_json(socket, ["1", "1", "lv:#{id}", "phx_join", join])
    assert [_, _, _, "phx_reply", %{"status" => "ok"}] = WebSocketClient.recv_json(socket)

    {host_id, host_join} = host_join()
    :ok = WebSocketClient.send_json(socket, ["2", "2", "lv:#{host_id}", "phx_join", host_join])
    assert_stale(recv_reply(socket, "2"))
  end

  # A Store restart forgets the open panels: their rejoin gets `stale`, so the
  # iframe reloads and its new dead render registers it again.
  test "a panel the Store forgot gets stale, not a silent close", %{port: port} do
    {id, join} = panel_join_params()
    Store.reset()
    socket = connect!(port)

    :ok = WebSocketClient.send_json(socket, ["1", "1", "lv:#{id}", "phx_join", join])
    assert ["1", "1", "lv:" <> ^id, "phx_reply", _] = reply = WebSocketClient.recv_json(socket)
    assert_stale(reply)
  end

  test "the V1 serializer gets its own stale reply", %{port: port} do
    {id, join} = host_join()
    socket = connect!(port, "1.0.0")
    topic = "lv:#{id}"

    :ok =
      WebSocketClient.send_json(socket, %{
        "topic" => topic,
        "event" => "phx_join",
        "payload" => join,
        "ref" => "1"
      })

    assert %{
             "topic" => ^topic,
             "event" => "phx_reply",
             "ref" => "1",
             "payload" => %{"status" => "error", "response" => %{"reason" => "stale"}}
           } = WebSocketClient.recv_json(socket)
  end

  # Frames the serializers read differently from a plain 5 element join.
  test "a join with extra elements closes; duplicate keys read as the serializer does",
       %{port: port} do
    {id, join} = host_join()

    socket = connect!(port)
    :ok = WebSocketClient.send_json(socket, ["1", "1", "lv:#{id}", "phx_join", join, "x"])
    assert WebSocketClient.closed?(socket)

    # Duplicate keys: our check and the serializer decode with the same JSON
    # library, so they read the same pair. Here that is the join: refused.
    socket = connect!(port, "1.0.0")

    raw =
      ~s({"topic":"lv:#{id}","event":"phx_join","topic":"phoenix","event":"heartbeat","ref":"1","payload":) <>
        Jason.encode!(join) <> "}"

    :ok = WebSocketClient.send_frame(socket, raw)

    assert %{
             "topic" => "lv:" <> _,
             "payload" => %{"status" => "error", "response" => %{"reason" => "stale"}}
           } = WebSocketClient.recv_json(socket)
  end

  test "non string refs still get a stale reply, not a crash", %{port: port} do
    {id, join} = host_join()
    socket = connect!(port)
    :ok = WebSocketClient.send_json(socket, [%{"a" => 1}, [1, 2], "lv:#{id}", "phx_join", join])

    assert [%{"a" => 1}, [1, 2], _topic, "phx_reply", _payload] =
             reply = WebSocketClient.recv_json(socket)

    assert_stale(reply)
  end

  test "other topics, binary frames and garbage close the connection", %{port: port} do
    for frame <- [
          {:text, Jason.encode!(["1", "1", "room:lobby", "phx_join", %{}])},
          {:text, Jason.encode!(["1", "1", "lvu:1", "phx_join", %{}])},
          {:binary, <<0, 1, 2>>},
          {:text, "not json"}
        ] do
      socket = connect!(port)
      {kind, payload} = frame
      :ok = WebSocketClient.send_frame(socket, payload, kind)
      assert WebSocketClient.closed?(socket), "expected a close for #{inspect(frame)}"
    end
  end

  test "the host socket's own check_origin applies, not only the endpoint's" do
    start_supervised!(PhoenixDevToolbar.OriginEndpoint)

    status = fn origin ->
      :get
      |> Plug.Test.conn("/__pdt/live/websocket?vsn=2.0.0")
      |> Plug.Conn.put_req_header("origin", origin)
      |> Plug.Conn.put_private(:phoenix_endpoint, PhoenixDevToolbar.OriginEndpoint)
      |> PhoenixDevToolbar.PanelSocket.upgrade()
      |> Map.fetch!(:status)
    end

    # The endpoint alone would allow its own host; the socket allows only this one.
    assert capture_log(fn -> assert status.("http://localhost") == 403 end) =~ "check origin"
    # Past the origin check, a plain GET is not an upgrade.
    assert status.("http://allowed.example") == 400
  end

  test "an endpoint without a LiveView socket gets a 404, never a crash" do
    conn =
      :get
      |> Plug.Test.conn("/__pdt/live/websocket")
      |> Plug.Conn.put_private(:phoenix_endpoint, PhoenixDevToolbar.NoSocketEndpoint)
      |> PhoenixDevToolbar.PanelSocket.upgrade()

    assert {conn.status, conn.halted} == {404, true}
  end

  test "a foreign origin is refused (the endpoint's check_origin)", %{port: port} do
    assert {:error, {403, _head}} =
             WebSocketClient.connect(port, "/__pdt/live/websocket?vsn=2.0.0", [
               {"Origin", "http://evil.example"}
             ])
  end

  test "a request that is not a WebSocket upgrade is refused", %{port: port} do
    assert WebSocketClient.get_status(port, "/__pdt/live/websocket?vsn=2.0.0") == 400
  end
end
