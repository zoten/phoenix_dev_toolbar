defmodule PhoenixDevToolbar.PanelLiveTest do
  # Uses the node global Store and the DemoWeb endpoint from test_helper.exs.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.ProcessHelpers
  import PhoenixDevToolbar.PageHelpers
  import PhoenixDevToolbar.PageHelpers

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @endpoint DemoWeb.Endpoint

  setup do
    Store.reset()
    on_exit(&Store.reset/0)

    transport = idle_process()
    request = Store.new_session(Session.new(:request, path: "/users"))
    %{conn: build_conn(), request: request.sid, transport: transport}
  end

  defp ms(n), do: System.convert_time_unit(n, :millisecond, :native)

  defp record(sid, plugin, kind, data, duration_ms) do
    :ok = Store.insert(sid, Event.new(plugin, kind, data, duration: ms(duration_ms)))
    sid |> Store.events() |> List.last()
  end

  defp query(sid, sql, duration_ms \\ 2) do
    record(
      sid,
      :ecto,
      :query,
      %{
        repo: DemoWeb.FakeRepo,
        sql: sql,
        params: "[]",
        source: "users",
        result: {:ok, 1},
        times: %{total_time: duration_ms * 1000},
        stacktrace: ["lib/demo/users.ex:9: DemoWeb.Users.list/0"],
        caller?: false
      },
      duration_ms
    )
  end

  defp response(sid) do
    record(
      sid,
      :request,
      :response,
      %{method: "GET", path: "/users", status: 200, content_type: "text/html", injected?: true},
      12
    )
  end

  defp live_view_session(parent, transport) do
    Store.new_session(
      Session.new(:live_view, parent: parent, owner: idle_process(), transport: transport)
    )
  end

  defp open(conn, sid) do
    {:ok, view, _html} = live(conn, "/__pdt/panel?sid=#{sid}")
    view
  end

  # What a browser sends when it loads a page.
  defp page_headers(conn) do
    conn
    |> Plug.Conn.put_req_header("accept", "text/html")
    |> Plug.Conn.put_req_header("sec-fetch-dest", "document")
  end

  # Delivers a pending update now instead of waiting for the 100 ms throttle.
  defp flush(view) do
    send(view.pid, :pdt_flush)
    _ = render(view)
  end

  test "shows the request and its LiveView's queries with a summary",
       %{conn: conn, request: request, transport: transport} do
    response(request)
    dead = query(request, "SELECT 1")
    live = live_view_session(request, transport)
    connected = query(live.sid, "SELECT 2", 5)

    view = open(conn, request)

    assert has_element?(view, "#pdt-badge-response", "200")
    # The lost connection notice is always rendered; CSS shows it (ADR 04).
    assert has_element?(view, "#pdt-offline[role=status]", "Disconnected")
    assert has_element?(view, "#pdt-badge-ecto-queries", "2 queries")
    assert has_element?(view, "#pdt-query-#{dead.seq}", "SELECT 1")
    assert has_element?(view, "#pdt-query-#{connected.seq}", "SELECT 2")
    # Which phase ran each query: the HTTP dead render or the connected LiveView.
    assert has_element?(view, "#pdt-query-#{dead.seq} .pdt-tag--http")
    assert has_element?(view, "#pdt-query-#{connected.seq} .pdt-tag--live")
  end

  test "says how many events the flood guard dropped", %{conn: conn, request: request} do
    Store.put_limits(events_per_second: 1)
    event = Event.new(:test, :ping, %{}, at: 0)
    for _ <- 1..3, do: Store.insert(request, event, 1_000)

    view = open(conn, request)

    assert has_element?(view, "#pdt-badge-dropped", "+2 dropped")
  end

  test "says how many older events the per page cap trimmed", %{conn: conn, request: request} do
    Store.put_limits(max_events: 2)
    for n <- 1..5, do: Store.insert(request, Event.new(:test, :ping, %{n: n}, at: 0))
    _ = :sys.get_state(Store)

    view = open(conn, request)

    assert has_element?(view, "#pdt-badge-trimmed", "3 older trimmed")
    refute has_element?(view, "#pdt-badge-dropped")
  end

  test "hints at stacktrace: true when a query has no origin", %{conn: conn, request: request} do
    :ok =
      Store.insert(
        request,
        Event.new(
          :ecto,
          :query,
          %{
            repo: DemoWeb.FakeRepo,
            sql: "SELECT 1",
            params: "[]",
            source: nil,
            result: {:ok, 1},
            times: %{query_time: 900, queue_time: 100},
            stacktrace: [],
            caller?: false
          },
          at: 0
        )
      )

    [event] = Store.events(request)
    view = open(conn, request)

    assert has_element?(view, "#pdt-query-#{event.seq} .pdt-hint", "stacktrace: true")
    assert has_element?(view, "#pdt-query-#{event.seq} .pdt-timings", "queue")
  end

  test "ties tabs to their panels for assistive technology", %{conn: conn, request: request} do
    view = open(conn, request)

    assert has_element?(view, ~s(#pdt-tab-ecto[aria-controls="pdt-section-ecto"][tabindex="0"]))
    assert has_element?(view, ~s(#pdt-tab-request[tabindex="-1"]))

    assert has_element?(
             view,
             ~s(#pdt-section-ecto[role="tabpanel"][aria-labelledby="pdt-tab-ecto"])
           )
  end

  test "offers the four docks in a menu the client controls", %{conn: conn, request: request} do
    view = open(conn, request)

    assert has_element?(view, ~s(#pdt-dock-picker[phx-update="ignore"]))
    assert has_element?(view, ~s(#pdt-dock[aria-controls="pdt-dock-menu"][aria-expanded="false"]))

    for dock <- ~w(bottom top left right) do
      assert has_element?(view, ~s(#pdt-dock-menu[hidden] #pdt-dock-#{dock}[data-pdt-dock="#{dock}"]))
    end
  end

  test "switches between the Ecto and Request tabs", %{conn: conn, request: request} do
    event = response(request)
    view = open(conn, request)

    assert has_element?(view, "#pdt-section-request[hidden]")

    view |> element("#pdt-tab-request") |> render_click()

    assert has_element?(view, "#pdt-section-ecto[hidden]")
    refute has_element?(view, "#pdt-section-request[hidden]")
    assert has_element?(view, "#pdt-request-#{event.seq}", "/users")
  end

  test "appends new events live", %{conn: conn, request: request} do
    view = open(conn, request)

    event = query(request, "SELECT live")
    Notify.event(request)
    flush(view)

    assert has_element?(view, "#pdt-query-#{event.seq}", "SELECT live")
    assert has_element?(view, "#pdt-badge-ecto-queries", "1 query")
  end

  test "picks up the LiveView when it connects after the panel opened",
       %{conn: conn, request: request, transport: transport} do
    view = open(conn, request)

    live = live_view_session(request, transport)
    event = query(live.sid, "SELECT from live")
    Notify.session(live)
    _ = render(view)

    assert has_element?(view, "#pdt-query-#{event.seq}")

    later = query(live.sid, "SELECT later")
    Notify.event(live.sid)
    flush(view)

    assert has_element?(view, "#pdt-query-#{later.seq}")
  end

  test "follows live navigation to the new page only",
       %{conn: conn, request: request, transport: transport} do
    first = live_view_session(request, transport)
    old = query(first.sid, "SELECT old page")
    view = open(conn, request)

    second = live_view_session(first.sid, transport)
    new = query(second.sid, "SELECT new page")
    Notify.session(second)
    _ = render(view)

    assert has_element?(view, "#pdt-query-#{new.seq}")
    refute has_element?(view, "#pdt-query-#{old.seq}")
  end

  test "ignores a duplicated tab of the same page",
       %{conn: conn, request: request, transport: transport} do
    first = live_view_session(request, transport)
    mine = query(first.sid, "SELECT mine")
    view = open(conn, request)

    copy = live_view_session(first.sid, idle_process())
    Notify.session(copy)
    _ = render(view)

    assert has_element?(view, "#pdt-query-#{mine.seq}")
  end

  test "explains when the page has no data", %{conn: conn} do
    for sid <- ["expired-sid", "../../etc"] do
      view = open(conn, sid)

      assert has_element?(view, "#pdt-empty")
    end
  end

  test "is never tracked as a page itself", %{conn: conn, request: request} do
    before = Store.sessions()

    conn |> page_headers() |> open(request)

    assert Store.sessions() == before
  end

  test "keeps following navigation after older sessions expired",
       %{conn: conn, request: request, transport: transport} do
    Store.put_limits(down_grace_ms: 0, ttl_ms: 0)
    first = live_view_session(request, transport)
    view = open(conn, request)

    second = live_view_session(first.sid, transport)
    Notify.session(second)
    _ = render(view)
    stop(first.owner)
    Store.sweep(System.system_time(:microsecond) + 1_000_000)
    assert Store.session(request) == :error

    third = live_view_session(second.sid, transport)
    event = query(third.sid, "SELECT third page")
    Notify.session(third)
    _ = render(view)

    assert has_element?(view, "#pdt-query-#{event.seq}")
    refute has_element?(view, "#pdt-empty")
  end

  test "shows the empty state instead of crashing while the Store restarts",
       %{conn: conn, request: request} do
    :ok = Supervisor.terminate_child(PhoenixDevToolbar.Supervisor, Store)
    on_exit(fn -> Supervisor.restart_child(PhoenixDevToolbar.Supervisor, Store) end)

    view = open(conn, request)

    assert has_element?(view, "#pdt-empty")
  end

  describe "end to end with a real host LiveView" do
    setup do
      Application.put_env(:phoenix_dev_toolbar, :repos, [DemoWeb.FakeRepo])
      attach_plugins()

      on_exit(fn ->
        Application.delete_env(:phoenix_dev_toolbar, :repos)
        attach_plugins()
      end)
    end

    test "follows the page from dead render through live events and navigation",
         %{conn: conn} do
      {host, sid} = visit(conn, "/demo")
      panel = open(build_conn(), sid)

      host |> render_hook("query", %{"sql" => "SELECT from mount page"})
      flush(panel)

      assert has_element?(panel, "#pdt-queries", "SELECT from mount page")
      assert has_element?(panel, "#pdt-badge-response", "200")

      {:ok, next, _html} = live_redirect(host, to: "/demo/other")
      _ = render(panel)
      next |> render_hook("query", %{"sql" => "SELECT after navigation"})
      flush(panel)

      assert has_element?(panel, "#pdt-queries", "SELECT after navigation")
      refute has_element?(panel, "#pdt-queries", "SELECT from mount page")
    end
  end

  test "loads only toolbar assets, relative to the mount path", %{conn: conn, request: request} do
    document =
      conn |> get("/__pdt/panel?sid=#{request}") |> html_response(200) |> LazyHTML.from_document()

    assert [_] =
             document
             |> LazyHTML.query(~s(link[href="/__pdt/assets/panel.css"]))
             |> Enum.to_list()

    assert [_] =
             document
             |> LazyHTML.query(
               ~s(script[src="/__pdt/assets/panel.js"][data-socket-path="/__pdt/live"])
             )
             |> Enum.to_list()
  end

  # Hardening (ADR 04): only the host page's own origin may frame the panel.
  test "the panel page refuses cross-site framing and MIME sniffing", %{conn: conn, request: sid} do
    conn = get(conn, "/__pdt/panel?sid=#{sid}")

    assert html_response(conn, 200)

    assert Plug.Conn.get_resp_header(conn, "content-security-policy") == [
             "frame-ancestors 'self'"
           ]

    assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end
end
