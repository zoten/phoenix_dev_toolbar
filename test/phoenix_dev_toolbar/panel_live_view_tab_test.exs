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

  # Opens the LiveView tab of the panel of `sid` on its sub-tab `sub`.
  defp open_lv(sid, sub) do
    view = open_tab(sid, "live_view")
    view |> element("#pdt-lv-tab-#{sub}") |> render_click()
    view
  end

  test "a LiveView tab with ARIA sub-tabs", %{request: request} do
    view = open_lv(request, "profiler")

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

    view = open_lv(request, "profiler")

    assert has_element?(view, "#pdt-profile-0", ~s(handle_event "save"))
    assert has_element?(view, ~s(#pdt-profile-0[data-pdt-count="2"]))
    assert has_element?(view, "#pdt-profile-1", "mount")
    assert has_element?(view, ~s(#pdt-profile-1[data-pdt-count="2"]))
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

    view = open_lv(request, "events")
    [save, boom, params] = Store.events(live)

    assert has_element?(view, "#pdt-lv-#{save.seq}", ~s(handle_event "save"))
    assert has_element?(view, "#pdt-lv-#{save.seq} [data-pdt-changed=count]")
    assert has_element?(view, ~s(#pdt-lv-#{save.seq} [data-pdt-changed-more="3"]), "+3 more")
    assert has_element?(view, "#pdt-lv-#{save.seq} [data-pdt-pushed=highlight]")
    assert has_element?(view, "#pdt-lv-#{save.seq} dd", ~s("Ada"))
    assert has_element?(view, "#pdt-lv-#{boom.seq}[data-pdt-error]", "RuntimeError")

    assert has_element?(
             view,
             "#pdt-lv-#{params.seq} [data-pdt-pushed-unavailable]",
             "unavailable"
           )
  end

  test "new callbacks reach the profiler and the log live", %{request: request, live: live} do
    view = open_lv(request, "events")
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

  test "a failed callback shows its call arguments when the event carries them",
       %{request: request, live: live} do
    callback(live, :handle_event, 1, %{
      event: "boom",
      changes: nil,
      error: "** (FunctionClauseError) no function clause",
      stacktrace: ["MyLive.handle_event/3"],
      stack_args: [~s(["save", %{"name" => "<b>ann</b>"}])]
    })

    callback(live, :handle_event, 1, %{event: "ok"})

    view = open_lv(request, "events")
    [failed, fine] = Store.events(live)

    assert has_element?(view, "#pdt-lv-#{failed.seq} [data-pdt-stack-args] dd code", "ann")
    refute has_element?(view, "#pdt-lv-#{fine.seq} [data-pdt-stack-args]")
  end

  test "rows carry data-pdt-* attributes with raw values (ADR 14)",
       %{request: request, live: live} do
    callback(live, :handle_event, 5, %{event: "save"})
    callback(live, :handle_info, 1, %{error: "** (RuntimeError) bad"})
    render_event(live, 2, nil)

    view = open_lv(request, "events")
    [save, failed, render] = Store.events(live)

    assert has_element?(
             view,
             ~s(#pdt-lv-#{save.seq}[data-pdt-row="callback"][data-pdt-sid="#{live}"]) <>
               ~s([data-pdt-seq="#{save.seq}"][data-pdt-duration-us="5000"]) <>
               ~s([data-pdt-callback="handle_event"][data-pdt-event="save"])
           )

    refute has_element?(view, "#pdt-lv-#{save.seq}[data-pdt-error]")

    assert has_element?(
             view,
             ~s(#pdt-lv-#{failed.seq}[data-pdt-callback="handle_info"][data-pdt-error])
           )

    assert has_element?(
             view,
             ~s(#pdt-lv-#{render.seq}[data-pdt-row="render"][data-pdt-duration-us="2000"])
           )

    view |> element("#pdt-lv-tab-profiler") |> render_click()

    assert has_element?(
             view,
             ~s(#pdt-profile-0[data-pdt-row="profile"][data-pdt-callback='handle_event "save"']) <>
               ~s([data-pdt-count="1"][data-pdt-total-us="5000"][data-pdt-max-us="5000"])
           )
  end

  describe "assigns snapshot" do
    test "explains when the page has no LiveView" do
      Store.reset()
      dead = Store.new_session(Session.new(:request, path: "/plain"))

      view = open_lv(dead.sid, "assigns")
      _ = render_async(view)

      assert has_element?(view, "#pdt-snapshot-missing", "No LiveView")
    end

    test "a read in flight is dropped when the LiveView rejoins", %{request: request, live: live} do
      # The owner never answers Debug.socket/1: the first read stays in flight.
      view = open_lv(request, "assigns")

      {:ok, session} = Store.session(live)
      gone = dead_process()
      {:ok, rejoined} = Store.claim(live, gone, session.transport)
      Notify.session(rejoined)
      _ = render(view)

      # Without cancelling, this would wait for the stuck read (5 s timeout).
      _ = render_async(view)
      assert has_element?(view, "#pdt-snapshot-missing", "not running")
    end

    test "explains when the LiveView is gone", %{request: request, live: live} do
      {:ok, session} = Store.session(live)
      gone = dead_process()
      Store.claim(live, gone, session.transport)

      view = open_lv(request, "assigns")
      _ = render_async(view)

      assert has_element?(view, "#pdt-snapshot-missing", "not running")
    end
  end

  describe "client events" do
    test "logs LiveView's window events forwarded by the loader", %{request: request} do
      view = open_lv(request, "events")

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
      assert has_element?(view, "#pdt-lv-client-1 [data-pdt-field=to]", "/posts")
      assert has_element?(view, "#pdt-lv-client-1 [data-pdt-phase=client]")

      assert has_element?(
               view,
               ~s(#pdt-lv-client-1[data-pdt-row="client"][data-pdt-event="phx:page-loading-start"])
             )
    end

    test "ignores unknown events and fields, caps strings, shows drops", %{request: request} do
      view = open_lv(request, "events")

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

      view = open_lv(dead.sid, "components")

      assert has_element?(view, "#pdt-tree-missing", "No LiveView")
    end
  end

  describe "element inspector" do
    @frames [%{"name" => "Demo.Core.button", "file" => "lib/x.ex", "line" => 12}]

    defp inspect_payload(overrides) do
      Map.merge(
        %{
          "root" => nil,
          "cid" => nil,
          "tag" => "button",
          "tag_line" => 7,
          "binding" => %{"event" => "phx-click", "name" => "save", "target" => nil},
          "frames" => @frames,
          "caller" => %{"file" => "lib/y.ex", "line" => 34}
        },
        overrides
      )
    end

    test "a dead render shows the strip only", %{request: request} do
      view = open_lv(request, "profiler")

      render_hook(view, "pdt:inspect", inspect_payload(%{}))

      assert has_element?(view, "#pdt-section-live_view:not([hidden]) #pdt-inspected")
      assert has_element?(view, "#pdt-inspected-tag", "button")
      assert has_element?(view, "#pdt-inspected-binding", ~s(phx-click="save"))
      assert has_element?(view, "#pdt-inspected-frame-0", "Demo.Core.button")
      assert has_element?(view, "#pdt-inspected-frame-0", "lib/x.ex:12")
      assert has_element?(view, "#pdt-inspected-caller", "lib/y.ex:34")
      assert has_element?(view, ~s(#pdt-lv-tab-profiler[aria-selected="true"]))
    end

    test "without annotations the strip says how to turn them on", %{request: request} do
      view = open_lv(request, "profiler")

      render_hook(view, "pdt:inspect", inspect_payload(%{"frames" => [], "caller" => nil}))

      assert has_element?(view, "#pdt-inspected-hint", "debug_heex_annotations")
    end

    test "garbage is ignored", %{request: request} do
      view = open_lv(request, "profiler")

      render_hook(view, "pdt:inspect", %{"tag" => 5, "frames" => "x", "binding" => []})

      refute has_element?(view, "#pdt-inspected-binding")
      assert has_element?(view, "#pdt-inspected")
    end

    test "links the frames to the editor when PLUG_EDITOR is set", %{request: request} do
      view = open_lv(request, "profiler")
      render_hook(view, "pdt:inspect", inspect_payload(%{}))
      refute has_element?(view, "#pdt-inspected-frame-0 a")

      previous = System.get_env("PLUG_EDITOR")
      System.put_env("PLUG_EDITOR", "vscode://file/__FILE__:__LINE__")

      on_exit(fn ->
        if previous,
          do: System.put_env("PLUG_EDITOR", previous),
          else: System.delete_env("PLUG_EDITOR")
      end)

      render_hook(view, "pdt:inspect", inspect_payload(%{}))

      assert has_element?(view, ~s(#pdt-inspected-frame-0 a[href$="/lib/x.ex:12"]))
      assert has_element?(view, ~s(#pdt-inspected-caller a[href$="/lib/y.ex:34"]))
    end
  end

  describe "element inspector with a real host LiveView" do
    setup do
      attach_plugins()
      on_exit(&attach_plugins/0)
    end

    # The root DOM id the tree rendered for the page's LiveView.
    defp tree_root(panel) do
      panel
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#pdt-tree-0")
      |> LazyHTML.attribute("data-pdt-root")
      |> List.first()
    end

    test "the tree rows carry their root and cid" do
      {_host, sid} = visit("/demo/components")
      panel = open_lv(sid, "components")
      _ = render_async(panel)

      root = tree_root(panel)
      assert String.starts_with?(root, "phx-")
      assert has_element?(panel, ~s(#pdt-tree-0[data-pdt-root="#{root}"]))
      assert has_element?(panel, ~s(#pdt-tree-0 li[data-pdt-root="#{root}"][data-pdt-cid]))
    end

    test "a component pick selects its node and shows the strip" do
      {_host, sid} = visit("/demo/components")
      panel = open_lv(sid, "components")
      _ = render_async(panel)
      root = tree_root(panel)
      panel |> element("#pdt-lv-tab-profiler") |> render_click()

      render_hook(panel, "pdt:inspect", inspect_payload(%{"root" => root, "cid" => 1}))
      _ = render_async(panel)

      assert has_element?(panel, ~s(#pdt-lv-tab-components[aria-selected="true"]))
      assert has_element?(panel, ~s(#pdt-tree [aria-current="true"][data-pdt-cid="1"]))
      assert has_element?(panel, "#pdt-inspected")
      assert_push_event(panel, "pdt:scroll-inspected", %{})
    end

    test "a pick of the page's own LiveView opens Assigns, selecting nothing else" do
      {_host, sid} = visit("/demo/components")
      panel = open_lv(sid, "components")
      _ = render_async(panel)
      root = tree_root(panel)

      render_hook(panel, "pdt:inspect", inspect_payload(%{"root" => root}))
      _ = render_async(panel)

      assert has_element?(panel, ~s(#pdt-lv-tab-assigns[aria-selected="true"]))
      assert has_element?(panel, "#pdt-inspected")
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
      panel = open_lv(sid, "profiler")

      host |> element("#counter-inc") |> render_click()
      flush(panel)

      assert has_element?(
               panel,
               "#pdt-profiler-table",
               ~s(DemoWeb.CounterComponent handle_event "inc")
             )

      assert has_element?(panel, "#pdt-profiler-table", "mount")

      panel |> element("#pdt-lv-tab-events") |> render_click()
      assert has_element?(panel, "#pdt-lv-events [data-pdt-changed=count]")
    end

    test "snapshots the host LiveView's assigns, redacted, and refreshes after callbacks" do
      {host, sid} = visit("/demo/components")
      panel = open_lv(sid, "assigns")
      _ = render_async(panel)

      assert has_element?(panel, "#pdt-snapshot-clicks", "0")
      assert has_element?(panel, "#pdt-snapshot-api_token", "[REDACTED]")
      refute render(panel) =~ "s3cret"

      visible(panel)
      host |> render_hook("click", %{})
      flush(panel)
      # Within a second of the first snapshot the refresh is scheduled, not run:
      # deliver the scheduled message now.
      Panel.send_now(panel.pid, Panels.LiveView, "pdt-panel-live_view", :snapshot)
      _ = render_async(panel)

      assert has_element?(panel, "#pdt-snapshot-clicks", "1")
      assert has_element?(panel, "#pdt-snapshot-clicks[data-pdt-snapshot-changed]")
    end

    test "shows the component tree, polling only while open and visible" do
      {_host, sid} = visit("/demo/components")
      panel = open_lv(sid, "components")
      _ = render_async(panel)

      assert has_element?(panel, "#pdt-tree-0", "DemoWeb.ComponentsLive")
      assert has_element?(panel, "#pdt-tree-0 li", "DemoWeb.CounterComponent")
      assert has_element?(panel, ~s(#pdt-lv-components[data-pdt-polling="off"]))

      visible(panel)
      assert has_element?(panel, ~s(#pdt-lv-components[data-pdt-polling="on"]))

      hidden(panel)
      assert has_element?(panel, ~s(#pdt-lv-components[data-pdt-polling="off"]))
    end

    test "a read of the previous LiveView that lands after a rejoin is dropped" do
      {host, sid} = visit("/demo/components")
      panel = open_lv(sid, "assigns")
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
      open_panel_tab(panel, "ecto")

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
      open_panel_tab(panel, "live_view")
      refute has_element?(panel, "#pdt-snapshot-clicks", "1")
      # What stays shown is the last snapshot taken before the page changed.
      assert has_element?(panel, "#pdt-snapshot-clicks code", ~r/^\s*0\s*$/)
    end

    test "a poll reads the host only while visible" do
      {host, sid} = visit("/demo/components")
      panel = open_lv(sid, "components")
      _ = render_async(panel)

      # A suspended host keeps any read in flight, so a started read shows.
      :ok = :sys.suspend(host.pid)

      Panel.send_now(panel.pid, Panels.LiveView, "pdt-panel-live_view", :tree_poll)
      assert has_element?(panel, ~s(#pdt-lv-components[data-pdt-reading="false"]))

      visible(panel)
      assert has_element?(panel, ~s(#pdt-lv-components[data-pdt-reading="true"]))

      :ok = :sys.resume(host.pid)
      _ = render_async(panel)
      assert has_element?(panel, ~s(#pdt-lv-components[data-pdt-reading="false"]))
    end

    test "the tree follows live navigation" do
      {host, sid} = visit("/demo")
      panel = open_lv(sid, "components")
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
      panel = open_lv(sid, "events")

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
