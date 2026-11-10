defmodule PhoenixDevToolbar.SystemPanelTest do
  # The System tab end to end (ADR 11): any process, by name, pid or link,
  # through the panel served by DemoWeb.Endpoint.
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.EnvHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers
  import PhoenixDevToolbar.ProcessHelpers

  alias PhoenixDevToolbar.Store

  setup do
    Store.reset()
    attach_plugins()
    on_exit(fn -> Store.reset() end)
  end

  defp open(conn \\ build_conn()) do
    {_host, sid} = visit("/demo")
    panel = open_panel(sid, conn: conn)
    panel |> element("#pdt-tab-system") |> render_click()
    render_hook(panel, "pdt:visibility", %{"open" => true, "visible" => true})
    panel
  end

  defp search(panel, ref),
    do: panel |> form("#pdt-system-search", %{"ref" => ref}) |> render_submit()

  test "a registered name is inspected: vitals, ancestors, stacktrace, relations" do
    panel = open()
    assert has_element?(panel, "#pdt-system-none")

    search(panel, "PhoenixDevToolbar.Store")

    assert has_element?(panel, "#pdt-system-target", "PhoenixDevToolbar.Store")
    assert has_element?(panel, "#pdt-system-memory")
    assert has_element?(panel, "#pdt-system-ancestors li")
    assert has_element?(panel, "#pdt-system-stacktrace li")
    assert has_element?(panel, "#pdt-system-links")
    assert has_element?(panel, "#pdt-system-crumb-0[aria-current=true]")
    refute has_element?(panel, "#pdt-system-none")
  end

  test "input that names no process says why" do
    panel = open()

    search(panel, "pdt_no_such_name_#{System.unique_integer([:positive])}")
    assert has_element?(panel, "#pdt-system-error", "No process is registered")

    search(panel, "<0.1")
    assert has_element?(panel, "#pdt-system-error", "Type a pid")
    refute has_element?(panel, "#pdt-system-target")
  end

  test "a relation link inspects in place; a crumb goes back" do
    agent = start_supervised!({Agent, fn -> :ok end})
    [{:links, [supervisor | _rest]}] = Process.info(agent, [:links])
    panel = open()

    search(panel, inspect(agent))
    assert has_element?(panel, "#pdt-system-target", inspect(agent))

    panel
    |> element(~s(#pdt-system-links button[phx-value-pid="#{inspect(supervisor)}"]))
    |> render_click()

    assert has_element?(panel, "#pdt-system-target", inspect(supervisor))
    assert has_element?(panel, "#pdt-system-crumb-1[aria-current=true]")

    panel |> element("#pdt-system-crumb-0") |> render_click()

    assert has_element?(panel, "#pdt-system-target", inspect(agent))
    refute has_element?(panel, "#pdt-system-crumb-1")
  end

  test "Read state shows a server's state, redacted" do
    agent = start_supervised!({Agent, fn -> %{name: "Ada", password: "hunter2"} end})
    panel = open()
    search(panel, inspect(agent))

    panel |> element("#pdt-system-status") |> render_click()
    _ = render_async(panel)

    assert has_element?(panel, "#pdt-system-state-value", "Ada")
    assert has_element?(panel, "#pdt-system-state-value", "[REDACTED]")
    refute has_element?(panel, "#pdt-system-state-value", "hunter2")
  end

  test "a plain process has no state to read" do
    pid = idle_process()
    panel = open()
    search(panel, inspect(pid))

    assert has_element?(panel, "#pdt-system-target", inspect(pid))
    refute has_element?(panel, "#pdt-system-status")
  end

  test "an exited process stays shown, still the current crumb" do
    pid = idle_process()
    panel = open()
    search(panel, inspect(pid))
    stop(pid)

    # Showing the panel again reads at once and finds it gone.
    render_hook(panel, "pdt:visibility", %{"open" => true, "visible" => false})
    render_hook(panel, "pdt:visibility", %{"open" => true, "visible" => true})

    assert has_element?(panel, "#pdt-system-dead")
    assert has_element?(panel, "#pdt-system-crumb-0[aria-current=true]")
  end

  test "without the System tab, Process tab pids are plain text" do
    PhoenixDevToolbar.Collector.attach([PhoenixDevToolbar.Plugins.Process])
    on_exit(fn -> attach_plugins() end)
    {_host, sid} = visit("/demo")
    panel = open_panel(sid)
    render_hook(panel, "pdt:visibility", %{"open" => true, "visible" => true})

    assert has_element?(panel, "#pdt-process-target-label code")
    refute has_element?(panel, "#pdt-process-target-label button")
    refute has_element?(panel, "#pdt-process-links button")
  end

  test "a process link in the Process tab opens it here" do
    {_host, sid} = visit("/demo")
    panel = open_panel(sid)
    panel |> element("#pdt-tab-process") |> render_click()
    render_hook(panel, "pdt:visibility", %{"open" => true, "visible" => true})

    panel |> element("#pdt-process-target-label button") |> render_click()

    assert has_element?(panel, "#pdt-tab-system[aria-selected=true]")
    assert has_element?(panel, "#pdt-system-target", "DemoWeb.PageLive")

    # A LiveView's format_status/2 lists its view, not its assigns.
    panel |> element("#pdt-system-status") |> render_click()
    _ = render_async(panel)
    assert has_element?(panel, "#pdt-system-state-value", "LiveView: DemoWeb.PageLive")
  end

  describe "trees" do
    test "a supervisor lists its children; a child link walks down" do
      sup =
        start_supervised!(%{
          id: :tree_sup,
          start: {Supervisor, :start_link, [[{Agent, fn -> :ok end}], [strategy: :one_for_one]]},
          type: :supervisor
        })

      [{Agent, agent, :worker, _modules}] = Supervisor.which_children(sup)
      panel = open()
      search(panel, inspect(sup))
      _ = render_async(panel)

      assert has_element?(panel, "#pdt-system-children-counts", "1 children")

      panel
      |> element(~s(#pdt-system-children-list button[phx-value-pid="#{inspect(agent)}"]))
      |> render_click()

      assert has_element?(panel, "#pdt-system-target", inspect(agent))
      refute has_element?(panel, "#pdt-system-children")
    end

    test "the applications list leads to each top supervisor, and back" do
      panel = open()
      _ = render_async(panel)
      toolbar_sup = inspect(Process.whereis(PhoenixDevToolbar.Supervisor))

      panel
      |> element(~s(#pdt-system-app-phoenix_dev_toolbar button[phx-value-pid="#{toolbar_sup}"]))
      |> render_click()

      _ = render_async(panel)
      assert has_element?(panel, "#pdt-system-target", toolbar_sup)
      assert has_element?(panel, "#pdt-system-children-list")

      panel |> element("#pdt-system-apps-button") |> render_click()
      _ = render_async(panel)
      assert has_element?(panel, "#pdt-system-app-phoenix_dev_toolbar")
      assert has_element?(panel, "#pdt-system-crumb-0")
    end
  end

  describe "message trace" do
    @describetag :trace_sessions

    test "records what it receives, redacted, until Stop" do
      pid = idle_process()
      panel = open()
      search(panel, inspect(pid))

      panel |> element("#pdt-system-trace-start") |> render_click()
      assert has_element?(panel, "#pdt-system-trace-status", "tracing")

      send(pid, {:login, %{password: "hunter2"}})
      _ = :sys.get_state(PhoenixDevToolbar.Tracer)
      panel |> element("#pdt-system-trace-stop") |> render_click()

      assert has_element?(panel, "#pdt-system-trace-status", "stopped")
      assert has_element?(panel, "#pdt-system-trace-list li", "[REDACTED]")
      refute has_element?(panel, "#pdt-system-trace-list li", "hunter2")
    end

    test "a protected process offers no trace" do
      panel = open()
      search(panel, "code_server")

      refute has_element?(panel, "#pdt-system-trace-start")
    end

    test "inspecting another process stops the trace" do
      pid = idle_process()
      panel = open()
      search(panel, inspect(pid))
      panel |> element("#pdt-system-trace-start") |> render_click()

      search(panel, "code_server")

      refute has_element?(panel, "#pdt-system-trace")
      assert PhoenixDevToolbar.Tracer.status(panel.pid) |> then(&(&1 == nil or not &1.running?))
    end
  end

  describe "top" do
    test "the top processes by queue, each a link to inspect" do
      pid = idle_process()
      for n <- 1..300, do: send(pid, {:n, n})
      panel = open()

      panel |> form("#pdt-system-top-form", %{"by" => "queue"}) |> render_change()
      panel |> form("#pdt-system-top-form", %{"by" => "queue"}) |> render_submit()
      _ = render_async(panel)

      link = ~s(#pdt-system-top-table button[phx-value-pid="#{inspect(pid)}"])
      assert has_element?(panel, link)
      assert has_element?(panel, "#pdt-system-top-by option[value=queue][selected]")

      panel |> element(link) |> render_click()
      assert has_element?(panel, "#pdt-system-target", inspect(pid))
    end

    test "an unknown sort reads nothing" do
      panel = open()

      render_submit(panel |> element("#pdt-system-top-form"), %{"by" => "pdt_nope"})
      _ = render_async(panel)

      refute has_element?(panel, "#pdt-system-top-table")
      assert has_element?(panel, "#pdt-system-top-by option[value=memory][selected]")
    end
  end

  describe "actions" do
    test "Kill waits for a confirm, then kills" do
      pid = idle_process()
      ref = Process.monitor(pid)
      panel = open()
      search(panel, inspect(pid))

      panel |> form("#pdt-system-kill-form", %{"reason" => "shutdown"}) |> render_submit()
      assert has_element?(panel, "#pdt-system-confirm-text", "shutdown")
      refute_received {:DOWN, ^ref, :process, ^pid, _reason}

      panel |> element("#pdt-system-cancel") |> render_click()
      refute has_element?(panel, "#pdt-system-confirm")

      panel |> form("#pdt-system-kill-form", %{"reason" => "kill"}) |> render_submit()

      ExUnit.CaptureLog.capture_log(fn ->
        panel |> element("#pdt-system-confirm") |> render_click()
      end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    end

    test "a protected process offers no action, and says why" do
      panel = open()
      search(panel, "code_server")

      assert has_element?(panel, "#pdt-system-actions-off", "Protected")
      refute has_element?(panel, "#pdt-system-kill")
    end

    test "a browser off this machine gets no actions, and is told how to allow them" do
      conn =
        Plug.Test.put_peer_data(build_conn(), %{
          address: {192, 168, 1, 20},
          port: 4000,
          ssl_cert: nil
        })

      pid = idle_process()
      panel = open(conn)
      search(panel, inspect(pid))

      assert has_element?(panel, "#pdt-system-actions-off", "actions: :any")
      refute has_element?(panel, "#pdt-system-kill")

      # Reading its messages or its state copies the process's data: refused too.
      refute has_element?(panel, "#pdt-system-peek")
      refute has_element?(panel, "#pdt-system-status")
      assert has_element?(panel, "#pdt-system-watch")
    end

    # Unset is the default: off. An explicit false looks the same.
    for {name, setup} <- [{"unset", :delete}, {"false", false}] do
      test "actions #{name} shows no actions, and a hint naming the option" do
        case unquote(setup) do
          :delete -> delete_app_env(:actions)
          value -> put_app_env(:actions, value)
        end

        agent = start_supervised!({Agent, fn -> :ok end})
        panel = open()
        search(panel, inspect(agent))

        refute has_element?(panel, "#pdt-system-kill")
        assert has_element?(panel, "#pdt-system-actions-off", "actions: :loopback")
        refute has_element?(panel, "#pdt-system-peek")
        refute has_element?(panel, "#pdt-system-status")
      end
    end

    test "Suspend freezes it until Resume" do
      pid = idle_process()
      panel = open()
      search(panel, inspect(pid))

      panel |> element("#pdt-system-suspend") |> render_click()

      ExUnit.CaptureLog.capture_log(fn ->
        panel |> element("#pdt-system-confirm") |> render_click()
      end)

      assert Process.info(pid, :status) == {:status, :suspended}
      assert has_element?(panel, "#pdt-system-resume")

      panel |> element("#pdt-system-resume") |> render_click()
      refute Process.info(pid, :status) == {:status, :suspended}
      refute has_element?(panel, "#pdt-system-resume")
    end

    test "Watch shows the exit reason once it goes down" do
      pid = idle_process()
      panel = open()
      search(panel, inspect(pid))

      panel |> element("#pdt-system-watch") |> render_click()
      assert has_element?(panel, "#pdt-system-watched-0", "alive")

      stop(pid)
      # The DOWN reaches the panel, which then updates the tab with a message of
      # its own: one render lets that one through too.
      _ = render(panel)

      assert has_element?(panel, "#pdt-system-watched-0", "exited at")
      assert has_element?(panel, "#pdt-system-watched-0 code", ":normal")
    end

    test "Peek shows the queued messages, redacted" do
      pid = idle_process()
      send(pid, {:login, %{password: "hunter2"}})
      panel = open()
      search(panel, inspect(pid))

      panel |> element("#pdt-system-peek") |> render_click()

      assert has_element?(panel, "#pdt-system-messages-list li", "[REDACTED]")
      refute has_element?(panel, "#pdt-system-messages-list li", "hunter2")
    end

    test "a watched exit reaches the System tab only: a strict plugin tab keeps working" do
      attach_plugins([PhoenixDevToolbar.TestPlugins.Strict])
      on_exit(fn -> attach_plugins() end)
      pid = idle_process()
      panel = open()
      search(panel, inspect(pid))
      panel |> element("#pdt-system-watch") |> render_click()

      stop(pid)
      # The DOWN reaches the panel, which then updates the tab with a message of
      # its own: one render lets that one through too.
      _ = render(panel)

      assert has_element?(panel, "#pdt-system-watched-0", "exited at")
      assert has_element?(panel, "#strict")
      refute has_element?(panel, "#pdt-disabled-strict")
      # The actions' context (client address, panel pids) is for built-in tabs only.
      assert has_element?(panel, "#strict[data-internal=false]")
    end

    test "Forget drops a watch; at ten, Watch is off" do
      panel = open()

      for _ <- 1..10 do
        search(panel, inspect(idle_process()))
        panel |> element("#pdt-system-watch") |> render_click()
      end

      search(panel, inspect(idle_process()))
      assert has_element?(panel, "#pdt-system-watch[disabled]")

      panel |> element("#pdt-system-forget-0") |> render_click()
      refute has_element?(panel, "#pdt-system-watch[disabled]")
      refute has_element?(panel, "#pdt-system-watched-9")
    end

    test "a panel that dies resumes what it suspended" do
      pid = ponger()
      # A registered name: the toolbar's own processes (whose code is in this
      # namespace) are protected from Suspend.
      Process.register(pid, :"pdt_suspend_target_#{System.unique_integer([:positive])}")
      panel = open()
      search(panel, inspect(pid))

      panel |> element("#pdt-system-suspend") |> render_click()

      ExUnit.CaptureLog.capture_log(fn ->
        panel |> element("#pdt-system-confirm") |> render_click()
      end)

      send(pid, {:ping, self()})
      refute_receive {:pong, ^pid}, 50

      # The test is linked to the panel LiveView (live/2).
      Process.flag(:trap_exit, true)
      ref = Process.monitor(panel.pid)
      Process.exit(panel.pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _pid, :killed}

      assert_receive {:pong, ^pid}, 1000
    end

    test "the kill reason survives a change and a cancel" do
      pid = idle_process()
      panel = open()
      search(panel, inspect(pid))

      panel |> form("#pdt-system-kill-form", %{"reason" => "crash"}) |> render_change()
      panel |> form("#pdt-system-kill-form", %{"reason" => "crash"}) |> render_submit()
      panel |> element("#pdt-system-cancel") |> render_click()

      assert has_element?(panel, "#pdt-system-kill-reason option[value=crash][selected]")
      refute has_element?(panel, "#pdt-disabled-system")
    end

    test "one action a second, and another once the window has passed" do
      clock = :atomics.new(1, signed: true)
      put_app_env(:clock_ms, fn -> :atomics.get(clock, 1) end)

      pid = idle_process()
      ref = Process.monitor(pid)
      panel = open()
      search(panel, inspect(pid))

      panel |> element("#pdt-system-suspend") |> render_click()

      ExUnit.CaptureLog.capture_log(fn ->
        panel |> element("#pdt-system-confirm") |> render_click()
      end)

      panel |> form("#pdt-system-kill-form", %{"reason" => "kill"}) |> render_submit()
      panel |> element("#pdt-system-confirm") |> render_click()

      assert has_element?(panel, "#pdt-system-action-note", "One action a second")
      refute_received {:DOWN, ^ref, :process, ^pid, _reason}

      # A second later (the injected clock, no waiting) the same click acts.
      :atomics.put(clock, 1, 1000)

      ExUnit.CaptureLog.capture_log(fn ->
        panel |> element("#pdt-system-confirm") |> render_click()
        assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      end)

      assert has_element?(panel, "#pdt-system-action-note", "Exit signal sent")
    end

    # The buttons are hidden with actions off, but the events are still
    # reachable: the server refuses them by policy, one test per action so the
    # one-a-second limiter never decides the outcome.
    defp forged_target(pid) do
      delete_app_env(:actions)
      panel = open()
      search(panel, inspect(pid))
      refute has_element?(panel, "#pdt-system-kill")
      {panel, with_target(panel, "#pdt-system")}
    end

    test "kill is refused" do
      pid = idle_process()
      ref = Process.monitor(pid)
      {panel, target} = forged_target(pid)

      render_click(target, "arm", %{"action" => "kill", "reason" => "kill"})
      render_click(target, "confirm", %{})

      refute has_element?(panel, "#pdt-system-confirm")
      refute_received {:DOWN, ^ref, :process, ^pid, _reason}
    end

    test "suspend is refused" do
      pid = ponger()
      Process.register(pid, :"pdt_forged_target_#{System.unique_integer([:positive])}")
      {panel, target} = forged_target(pid)

      render_click(target, "arm", %{"action" => "suspend"})
      render_click(target, "confirm", %{})

      refute has_element?(panel, "#pdt-system-confirm")
      assert PhoenixDevToolbar.Suspender.suspended() == %{}
      send(pid, {:ping, self()})
      assert_receive {:pong, ^pid}
    end

    test "reading the message queue is refused" do
      pid = idle_process()
      send(pid, :queued)
      {panel, target} = forged_target(pid)

      render_click(target, "peek", %{})

      refute has_element?(panel, "#pdt-system-messages-list")
    end

    test "reading the state is refused" do
      agent = start_supervised!({Agent, fn -> :hidden end})
      {panel, target} = forged_target(agent)

      render_click(target, "status", %{})
      _ = render(panel)

      refute has_element?(panel, "#pdt-system-state-value")
    end

    test "tracing is refused" do
      pid = idle_process()
      {panel, target} = forged_target(pid)

      render_click(target, "trace", %{})

      refute has_element?(panel, "#pdt-system-trace-list")
      refute has_element?(panel, "#pdt-system-trace-status")
      assert PhoenixDevToolbar.Tracer.status(panel.pid) == nil
    end
  end
end
