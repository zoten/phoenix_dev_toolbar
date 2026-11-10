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

  describe "origin (the panel is always same origin with its page)" do
    @refusals_key {PhoenixDevToolbar.PanelSocket, :logged_refusals}

    # Refusals are logged once per pair: start each test with none logged.
    setup do
      :persistent_term.erase(@refusals_key)
      on_exit(fn -> :persistent_term.erase(@refusals_key) end)
    end

    # Direct calls to upgrade/1: a Plug.Test conn has no Host header, so the
    # request's own host is `www.example.com`.
    defp upgrade_status(endpoint, origin, host \\ nil) do
      # Raw header lists: put_req_header/3 refuses "host" and replaces repeats.
      headers = Enum.map(List.wrap(origin), &{"origin", &1})
      headers = if(host, do: [{"host", host} | headers], else: headers)
      conn = Plug.Test.conn(:get, "/__pdt/live/websocket?vsn=2.0.0")
      conn = %{conn | req_headers: headers ++ conn.req_headers}

      conn
      |> Plug.Conn.put_private(:phoenix_endpoint, endpoint)
      |> PhoenixDevToolbar.PanelSocket.upgrade()
      |> Map.fetch!(:status)
    end

    test "a foreign origin is refused even when the host socket has check_origin: false" do
      start_supervised!(PhoenixDevToolbar.OriginEndpoint)

      assert capture_log(fn ->
               assert upgrade_status(PhoenixDevToolbar.OriginEndpoint, "http://evil.example") ==
                        403
             end) =~ "Origin"
    end

    test "a missing origin is refused" do
      start_supervised!(PhoenixDevToolbar.OriginEndpoint)

      capture_log(fn ->
        assert upgrade_status(PhoenixDevToolbar.OriginEndpoint, nil) == 403
      end)
    end

    test "the request's own origin passes (a plain GET is then not an upgrade: 400)" do
      start_supervised!(PhoenixDevToolbar.OriginEndpoint)
      endpoint = PhoenixDevToolbar.OriginEndpoint

      assert upgrade_status(endpoint, "http://www.example.com") == 400
      assert upgrade_status(endpoint, "http://WWW.Example.com:80") == 400
      assert upgrade_status(endpoint, "https://www.example.com") == 400
      assert upgrade_status(endpoint, "http://localhost:4000", "localhost:4000") == 400
    end

    test "the Host header decides: IPv6 literals, case and ports" do
      start_supervised!(PhoenixDevToolbar.OriginEndpoint)
      endpoint = PhoenixDevToolbar.OriginEndpoint

      # HostCheck is not on this direct path: only the origin rule is exercised.
      assert upgrade_status(endpoint, "http://[::1]:4000", "[::1]:4000") == 400
      assert upgrade_status(endpoint, "http://localhost:4000", "LOCALHOST:4000") == 400

      capture_log(fn ->
        assert upgrade_status(endpoint, "http://localhost", "localhost:4000") == 403
      end)
    end

    test "no Host header falls back to the request host, several Host headers are refused" do
      start_supervised!(PhoenixDevToolbar.OriginEndpoint)
      endpoint = PhoenixDevToolbar.OriginEndpoint
      conn = Plug.Test.conn(:get, "/__pdt/live/websocket?vsn=2.0.0")

      headers = [
        {"host", "localhost:4000"},
        {"host", "localhost:4000"},
        {"origin", "http://localhost:4000"}
      ]

      log =
        capture_log(fn ->
          status =
            %{conn | req_headers: headers}
            |> Plug.Conn.put_private(:phoenix_endpoint, endpoint)
            |> PhoenixDevToolbar.PanelSocket.upgrade()
            |> Map.fetch!(:status)

          assert status == 403
        end)

      assert log =~ "Host"
    end

    test "a refusal names the Origin and the Host, once per pair" do
      start_supervised!(PhoenixDevToolbar.OriginEndpoint)
      endpoint = PhoenixDevToolbar.OriginEndpoint

      log =
        capture_log(fn ->
          for _repeat <- 1..3,
              do: upgrade_status(endpoint, "http://app.example", "localhost:4000")
        end)

      assert log =~ "app.example"
      assert log =~ "localhost:4000"
      assert log =~ "rewrites the Host"
      assert length(String.split(log, "refused a panel socket request")) == 2
    end

    test "scheme, host and port must be sane: other hosts, ports and schemes are refused" do
      start_supervised!(PhoenixDevToolbar.OriginEndpoint)
      endpoint = PhoenixDevToolbar.OriginEndpoint

      capture_log(fn ->
        for {origin, host} <- [
              {"http://www.example.com.evil.example", nil},
              {"http://localhost:3000", "localhost:4000"},
              {"http://localhost:4000", "localhost"},
              {"null", nil},
              {"file://www.example.com", nil},
              {"ftp://www.example.com", nil},
              {"", nil},
              {"not a url", nil}
            ] do
          assert upgrade_status(endpoint, origin, host) == 403, "#{origin} -> #{host}"
        end

        assert upgrade_status(endpoint, ["http://www.example.com", "http://evil.example"]) == 403
      end)
    end
  end

  test "an endpoint without a LiveView socket gets a 404, never a crash" do
    conn =
      :get
      |> Plug.Test.conn("/__pdt/live/websocket")
      |> Plug.Conn.put_private(:phoenix_endpoint, PhoenixDevToolbar.NoSocketEndpoint)
      |> PhoenixDevToolbar.PanelSocket.upgrade()

    assert {conn.status, conn.halted} == {404, true}
  end

  test "a foreign or missing origin is refused over a real socket", %{port: port} do
    path = "/__pdt/live/websocket?vsn=2.0.0"

    capture_log(fn ->
      assert {:error, {403, _head}} =
               WebSocketClient.connect(port, path, [{"Origin", "http://evil.example"}])

      assert {:error, {403, _head}} = WebSocketClient.connect(port, path)
    end)
  end

  test "a Host that could be rebound gets 403 on the upgrade", %{port: port} do
    path = "/__pdt/live/websocket?vsn=2.0.0"

    capture_log(fn ->
      assert {:error, {403, _head}} =
               WebSocketClient.connect(port, path, [
                 {"Host", "evil.example"},
                 {"Origin", "http://evil.example"}
               ])
    end)
  end

  test "a request that is not a WebSocket upgrade is refused", %{port: port} do
    assert WebSocketClient.get_status(port, "/__pdt/live/websocket?vsn=2.0.0", [
             {"Origin", "http://localhost:#{port}"}
           ]) == 400
  end

  # The socket's peer is loopback here, so only the proxy header tells the panel
  # its client is elsewhere. Observed through the Eval tab (allow: :eval), which
  # shows its code form to a loopback client and a notice to any other.
  describe "a join behind a proxy" do
    defp eval_tab_diff(port, headers) do
      capture_log(fn -> attach_plugins([{PhoenixDevToolbar.Plugins.Eval, allow: :eval}]) end)
      {id, join} = panel_join_params()

      {:ok, socket} =
        WebSocketClient.connect(port, "/__pdt/live/websocket?vsn=2.0.0", [
          {"Origin", "http://localhost:#{port}"} | headers
        ])

      :ok = WebSocketClient.send_json(socket, ["1", "1", "lv:#{id}", "phx_join", join])

      [_, _, _, "phx_reply", %{"status" => "ok", "response" => response}] =
        recv_reply(socket, "1")

      inspect(response, limit: :infinity, printable_limit: :infinity)
    end

    test "a direct join is a loopback client; one with X-Forwarded-For is not", %{port: port} do
      assert eval_tab_diff(port, []) =~ "pdt-eval-form"

      proxied = eval_tab_diff(port, [{"X-Forwarded-For", "203.0.113.9"}])
      assert proxied =~ "pdt-eval-off"
      refute proxied =~ "pdt-eval-form"
    end
  end
end
