defmodule PhoenixDevToolbar.PanelSocketTest do
  # The panel's own LiveView socket (ADR 04), end to end: a real Bandit server,
  # a real WebSocket, the panel LiveView joined with no session cookie and no
  # CSRF token (what made the host socket refuse it on pages without one).
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.WebSocketClient

  @endpoint DemoWeb.Endpoint

  setup do
    Store.reset()
    Collector.attach(PhoenixDevToolbar.Application.plugins())
    on_exit(fn -> Store.reset() end)

    server = start_supervised!({Bandit, plug: DemoWeb.Endpoint, port: 0, ip: :loopback})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{port: port}
  end

  # A page's sid, then the panel's LiveView join params from its dead render.
  defp panel_join_params do
    conn =
      build_conn()
      |> Plug.Conn.put_req_header("accept", "text/html")
      |> Plug.Conn.put_req_header("sec-fetch-dest", "document")
      |> get("/demo")

    [sid] =
      conn
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("script[data-pdt-sid]")
      |> LazyHTML.attribute("data-pdt-sid")

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
  # session checks. Only registered panels may join; anything else closes.
  test "a host LiveView cannot be joined through the panel socket", %{port: port} do
    host =
      build_conn()
      |> get("/demo")
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-phx-session]")

    [id] = LazyHTML.attribute(host, "id")
    [session] = LazyHTML.attribute(host, "data-phx-session")
    static = host |> LazyHTML.attribute("data-phx-static") |> List.first()

    join = %{
      "url" => "http://localhost/demo",
      "session" => session,
      "static" => static,
      "params" => %{}
    }

    {:ok, socket} =
      WebSocketClient.connect(port, "/__pdt/live/websocket?vsn=2.0.0", [
        {"Origin", "http://localhost:#{port}"}
      ])

    :ok = WebSocketClient.send_json(socket, ["1", "1", "lv:#{id}", "phx_join", join])
    assert WebSocketClient.closed?(socket)
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
