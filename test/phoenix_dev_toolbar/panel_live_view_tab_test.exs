defmodule PhoenixDevToolbar.PanelLiveViewTabTest do
  # The LiveView tab of the panel. Uses the node global Store and the DemoWeb
  # endpoint from test_helper.exs.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.ProcessHelpers
  import PhoenixDevToolbar.PageHelpers

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.Panel
  alias PhoenixDevToolbar.Panels
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

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

  defp open_tab(view, sub) do
    view |> element("#pdt-tab-live_view") |> render_click()
    view |> element("#pdt-lv-tab-#{sub}") |> render_click()
    view
  end

  test "a LiveView tab with ARIA sub-tabs", %{request: request} do
    view = open_panel(request) |> open_tab("profiler")

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

    view = open_panel(request) |> open_tab("profiler")

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

    view = open_panel(request) |> open_tab("events")
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
    view = open_panel(request) |> open_tab("events")
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

  describe "assigns snapshot" do
    test "explains when the page has no LiveView" do
      Store.reset()
      dead = Store.new_session(Session.new(:request, path: "/plain"))

      view = open_panel(dead.sid) |> open_tab("assigns")
      _ = render_async(view)

      assert has_element?(view, "#pdt-snapshot-missing", "No LiveView")
    end

    test "a read in flight is dropped when the LiveView rejoins", %{request: request, live: live} do
      # The owner never answers Debug.socket/1: the first read stays in flight.
      view = open_panel(request) |> open_tab("assigns")

      {:ok, session} = Store.session(live)
      gone = spawn(fn -> :ok end)
      ref = Process.monitor(gone)
      assert_receive {:DOWN, ^ref, :process, ^gone, _reason}
      {:ok, rejoined} = Store.claim(live, gone, session.transport)
      Notify.session(rejoined)
      _ = render(view)

      # Without cancelling, this would wait for the stuck read (5 s timeout).
      _ = render_async(view)
      assert has_element?(view, "#pdt-snapshot-missing", "not running")
    end

    test "explains when the LiveView is gone", %{request: request, live: live} do
      {:ok, session} = Store.session(live)
      gone = spawn(fn -> :ok end)
      ref = Process.monitor(gone)
      assert_receive {:DOWN, ^ref, :process, ^gone, _reason}
      Store.claim(live, gone, session.transport)

      view = open_panel(request) |> open_tab("assigns")
      _ = render_async(view)

      assert has_element?(view, "#pdt-snapshot-missing", "not running")
    end
  end

  describe "client events" do
    test "logs LiveView's window events forwarded by the loader", %{request: request} do
      view = open_panel(request) |> open_tab("events")

      render_hook(view, "pdt:client", %{
        "event" => %{
          "type" => "phx:page-loading-start",
          "at" => 1_700_000_000_000,
          "kind" => "patch",
          "to" => "/posts"
        },
        "dropped" => 0
      })

      assert has_element?(view, "#pdt-lv-client-1", "phx:page-loading-start")
      assert has_element?(view, "#pdt-lv-client-1 .pdt-tag", "/posts")
      assert has_element?(view, "#pdt-lv-client-1 .pdt-tag--client")
    end

    test "ignores unknown events and fields, caps strings, shows drops", %{request: request} do
      view = open_panel(request) |> open_tab("events")

      render_hook(view, "pdt:client", %{
        "event" => %{"type" => "phx:custom", "at" => 1},
        "dropped" => 0
      })

      render_hook(view, "pdt:client", %{"event" => "nope", "dropped" => "x"})
      render_hook(view, "pdt:client", %{"event" => nil, "dropped" => 3})
      assert has_element?(view, "#pdt-client-dropped", "3")
      refute has_element?(view, "[id^=pdt-lv-client-]")

      render_hook(view, "pdt:client", %{
        "event" => %{
          "type" => "phx:navigate",
          "at" => 2,
          "href" => String.duplicate("h", 5000),
          "evil" => "x"
        },
        "dropped" => 7
      })

      assert has_element?(view, "#pdt-lv-client-1", "phx:navigate")
      refute render(view) =~ "evil"
      refute render(view) =~ String.duplicate("h", 300)
      assert has_element?(view, "#pdt-client-dropped", "7")
    end
  end

  describe "component tree" do
    test "explains when the page has no LiveView" do
      Store.reset()
      dead = Store.new_session(Session.new(:request, path: "/plain"))

      view = open_panel(dead.sid) |> open_tab("components")

      assert has_element?(view, "#pdt-tree-missing", "No LiveView")
    end
  end

  describe "end to end with a real host LiveView" do
    setup do
      attach_plugins()

      on_exit(fn ->
        attach_plugins()
      end)
    end

    # The LiveView session of the page whose request sid is `sid`.
    defp sid_of_live(sid) do
      Enum.find_value(Store.sessions(), fn
        %Session{kind: :live_view, parent: ^sid, sid: live} -> live
        _other -> nil
      end)
    end

    test "profiles the host LiveView and its component" do
      {host, sid} = visit("/demo/components")
      panel = open_panel(sid) |> open_tab("profiler")

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

    test "snapshots the host LiveView's assigns, redacted, and refreshes after callbacks" do
      {host, sid} = visit("/demo/components")
      panel = open_panel(sid) |> open_tab("assigns")
      _ = render_async(panel)

      assert has_element?(panel, "#pdt-snapshot-clicks", "0")
      assert has_element?(panel, "#pdt-snapshot-api_token", "[REDACTED]")
      refute render(panel) =~ "s3cret"

      render_hook(panel, "pdt:visibility", %{"open" => true, "visible" => true})
      host |> render_hook("click", %{})
      flush(panel)
      # Within a second of the first snapshot the refresh is scheduled, not run:
      # deliver the scheduled message now.
      Panel.send_now(panel.pid, Panels.LiveView, "pdt-panel-live_view", :snapshot)
      _ = render_async(panel)

      assert has_element?(panel, "#pdt-snapshot-clicks", "1")
      assert has_element?(panel, "#pdt-snapshot-clicks.pdt-snapshot--changed")
    end

    test "shows the component tree, polling only while open and visible" do
      {_host, sid} = visit("/demo/components")
      panel = open_panel(sid) |> open_tab("components")
      _ = render_async(panel)

      assert has_element?(panel, "#pdt-tree-0", "DemoWeb.ComponentsLive")
      assert has_element?(panel, "#pdt-tree-0 li", "DemoWeb.CounterComponent")
      assert has_element?(panel, ~s(#pdt-lv-components[data-pdt-polling="off"]))

      render_hook(panel, "pdt:visibility", %{"open" => true, "visible" => true})
      assert has_element?(panel, ~s(#pdt-lv-components[data-pdt-polling="on"]))

      render_hook(panel, "pdt:visibility", %{"open" => true, "visible" => false})
      assert has_element?(panel, ~s(#pdt-lv-components[data-pdt-polling="off"]))
    end

    test "a read of the previous LiveView that lands after a rejoin is dropped" do
      {host, sid} = visit("/demo/components")
      panel = open_panel(sid) |> open_tab("assigns")
      _ = render_async(panel)
      assert has_element?(panel, "#pdt-snapshot-clicks", "0")

      # The next read sees clicks: 1, and is held by the suspended host.
      host |> render_hook("click", %{})
      :ok = :sys.suspend(host.pid)
      {:links, before} = Process.info(panel.pid, :links)
      panel |> element("#pdt-snapshot-refresh") |> render_click()
      {:links, now} = Process.info(panel.pid, :links)
      [task] = now -- before
      ref = Process.monitor(task)

      # With the tab hidden no new read replaces the pending one on rejoin.
      panel |> element("#pdt-tab-ecto") |> render_click()

      # The rejoin is queued first, the read's result after it.
      :ok = :sys.suspend(panel.pid)
      {:ok, session} = Store.session(sid_of_live(sid))
      {:ok, rejoined} = Store.claim(session.sid, idle_process(), session.transport)
      Notify.session(rejoined)
      :ok = :sys.resume(host.pid)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}
      :ok = :sys.resume(panel.pid)
      _ = render(panel)

      # Back on the tab a fresh read starts (the new owner never answers): the
      # old LiveView's clicks: 1 must not show as the new page's.
      panel |> element("#pdt-tab-live_view") |> render_click()
      refute has_element?(panel, "#pdt-snapshot-clicks", "1")
    end

    test "a poll reads the host only while visible" do
      {host, sid} = visit("/demo/components")
      panel = open_panel(sid) |> open_tab("components")
      _ = render_async(panel)

      # A suspended host keeps any read in flight, so a started read shows.
      :ok = :sys.suspend(host.pid)

      Panel.send_now(panel.pid, Panels.LiveView, "pdt-panel-live_view", :tree_poll)
      assert has_element?(panel, ~s(#pdt-lv-components[data-pdt-reading="false"]))

      render_hook(panel, "pdt:visibility", %{"open" => true, "visible" => true})
      assert has_element?(panel, ~s(#pdt-lv-components[data-pdt-reading="true"]))

      :ok = :sys.resume(host.pid)
      _ = render_async(panel)
      assert has_element?(panel, ~s(#pdt-lv-components[data-pdt-reading="false"]))
    end

    test "the tree follows live navigation" do
      {host, sid} = visit("/demo")
      panel = open_panel(sid) |> open_tab("components")
      _ = render_async(panel)

      assert has_element?(panel, "#pdt-tree-0", "DemoWeb.PageLive")
      refute has_element?(panel, "#pdt-tree", "CounterComponent")

      {:ok, _next, _html} = live_redirect(host, to: "/demo/components")
      _ = render(panel)
      _ = render_async(panel)

      assert has_element?(panel, "#pdt-tree-0", "DemoWeb.ComponentsLive")
      assert has_element?(panel, "#pdt-tree-0 li", "DemoWeb.CounterComponent")
    end

    test "live navigation keeps the client events that announced it" do
      {host, sid} = visit("/demo")
      panel = open_panel(sid) |> open_tab("events")

      render_hook(panel, "pdt:client", %{
        "event" => %{"type" => "phx:page-loading-start", "at" => 1, "kind" => "redirect"},
        "dropped" => 0
      })

      {:ok, _next, _html} = live_redirect(host, to: "/demo/other")
      _ = render(panel)

      assert has_element?(panel, "#pdt-lv-client-1", "phx:page-loading-start")
    end
  end
end
