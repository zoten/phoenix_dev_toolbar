defmodule PhoenixDevToolbar.PanelLiveViewTabTest do
  # The LiveView tab of the panel. Uses the node global Store and the DemoWeb
  # endpoint from test_helper.exs.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.ProcessHelpers

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @endpoint DemoWeb.Endpoint

  setup do
    Store.reset()
    on_exit(&Store.reset/0)

    request = Store.new_session(Session.new(:request, path: "/demo"))

    live =
      Store.new_session(
        Session.new(:live_view,
          parent: request.sid,
          owner: idle_process(),
          transport: idle_process(),
          view: DemoWeb.PageLive,
          path: "/demo"
        )
      )

    %{request: request.sid, live: live.sid}
  end

  defp ms(n), do: System.convert_time_unit(n, :millisecond, :native)

  defp callback(sid, callback, duration_ms, data \\ %{}) do
    data =
      Map.merge(
        %{
          callback: callback,
          view: DemoWeb.PageLive,
          component: nil,
          cid: nil,
          id: nil,
          count: nil,
          connected?: true,
          event: nil,
          params: nil,
          changes: %{keys: [], values: %{}, omitted: 0},
          pushed: [],
          error: nil
        },
        data
      )

    :ok = Store.insert(sid, Event.new(:live_view, :callback, data, duration: ms(duration_ms)))
  end

  defp render_event(sid, duration_ms, component) do
    data = %{
      view: DemoWeb.PageLive,
      component: component,
      cid: component && 1,
      id: component && ~s("c"),
      force?: false,
      changed?: true,
      error: nil
    }

    :ok = Store.insert(sid, Event.new(:live_view, :render, data, duration: ms(duration_ms)))
  end

  defp open(sid) do
    {:ok, view, _html} = live(build_conn(), "/__pdt/panel?sid=#{sid}")
    view
  end

  defp open_tab(view, sub) do
    view |> element("#pdt-tab-live_view") |> render_click()
    view |> element("#pdt-lv-tab-#{sub}") |> render_click()
    view
  end

  defp flush(view) do
    send(view.pid, :pdt_flush)
    _ = render(view)
  end

  test "a LiveView tab with ARIA sub-tabs", %{request: request} do
    view = open(request) |> open_tab("profiler")

    assert has_element?(view, ~s|#pdt-section-live_view[role="tabpanel"]:not([hidden])|)
    assert has_element?(view, ~s(#pdt-lv-tab-profiler[role="tab"][aria-selected="true"]))

    assert has_element?(
             view,
             ~s(#pdt-lv-tab-events[aria-controls="pdt-lv-events"][tabindex="-1"])
           )

    assert has_element?(view, "#pdt-lv-profiler:not([hidden])")
    assert has_element?(view, "#pdt-lv-events[hidden]")
  end

  test "the profiler aggregates callbacks and renders, slowest first",
       %{request: request, live: live} do
    callback(request, :mount, 3)
    callback(live, :mount, 2)
    callback(live, :handle_event, 5, %{event: "save"})
    callback(live, :handle_event, 1, %{event: "save"})
    render_event(live, 1, nil)
    render_event(live, 1, DemoWeb.CounterComponent)

    view = open(request) |> open_tab("profiler")

    assert has_element?(view, "#pdt-profile-0", ~s(handle_event "save"))
    assert has_element?(view, "#pdt-profile-0 .pdt-count", "2")
    assert has_element?(view, "#pdt-profile-1", "mount")
    assert has_element?(view, "#pdt-profile-1 .pdt-count", "2")
    assert has_element?(view, "#pdt-profiler-table", "DemoWeb.CounterComponent")
    assert has_element?(view, "#pdt-badge-live", "4 callbacks")
  end

  test "the event log shows each callback with its diff, pushes and errors",
       %{request: request, live: live} do
    callback(live, :handle_event, 2, %{
      event: "save",
      params: ~s(%{"name" => "Ada"}),
      changes: %{keys: [:count, :name], values: %{count: "2", name: ~s("Ada")}, omitted: 3},
      pushed: ["highlight"]
    })

    callback(live, :handle_event, 1, %{
      event: "boom",
      changes: nil,
      error: "** (RuntimeError) bad"
    })

    callback(live, :handle_params, 1, %{pushed: :unavailable})

    view = open(request) |> open_tab("events")
    [save, boom, params] = Store.events(live)

    assert has_element?(view, "#pdt-lv-#{save.seq}", ~s(handle_event "save"))
    assert has_element?(view, "#pdt-lv-#{save.seq} .pdt-changed", "count")
    assert has_element?(view, "#pdt-lv-#{save.seq} .pdt-changed", "+3 more")
    assert has_element?(view, "#pdt-lv-#{save.seq} .pdt-pushed", "highlight")
    assert has_element?(view, "#pdt-lv-#{save.seq} dd", ~s("Ada"))
    assert has_element?(view, "#pdt-lv-#{boom.seq}.pdt-row--error", "RuntimeError")
    assert has_element?(view, "#pdt-lv-#{params.seq} .pdt-pushed", "unavailable")
  end

  test "new callbacks reach the profiler and the log live", %{request: request, live: live} do
    view = open(request) |> open_tab("events")
    refute has_element?(view, "#pdt-badge-live")

    callback(live, :handle_event, 4, %{event: "inc"})
    Notify.event(live)
    flush(view)

    [event] = Store.events(live)
    assert has_element?(view, "#pdt-lv-#{event.seq}", "inc")
    assert has_element?(view, "#pdt-badge-live", "1 callback")

    view |> element("#pdt-lv-tab-profiler") |> render_click()
    assert has_element?(view, "#pdt-profile-0", "inc")
  end

  describe "end to end with a real host LiveView" do
    setup do
      PhoenixDevToolbar.Collector.attach(PhoenixDevToolbar.Application.plugins())

      on_exit(fn ->
        PhoenixDevToolbar.Collector.attach(PhoenixDevToolbar.Application.plugins())
      end)
    end

    test "profiles the host LiveView and its component" do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("accept", "text/html")
        |> Plug.Conn.put_req_header("sec-fetch-dest", "document")
        |> get("/demo/components")

      [sid] =
        conn
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("script[data-pdt-sid]")
        |> LazyHTML.attribute("data-pdt-sid")

      {:ok, host, _html} = live(conn)
      panel = open(sid) |> open_tab("profiler")

      host |> element("#counter-inc") |> render_click()
      flush(panel)

      assert has_element?(
               panel,
               "#pdt-profiler-table",
               ~s(DemoWeb.CounterComponent handle_event "inc")
             )

      assert has_element?(panel, "#pdt-profiler-table", "mount")

      panel |> element("#pdt-lv-tab-events") |> render_click()
      assert has_element?(panel, "#pdt-lv-events .pdt-changed", "count")
    end
  end
end
