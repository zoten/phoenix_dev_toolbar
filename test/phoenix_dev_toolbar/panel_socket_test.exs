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
