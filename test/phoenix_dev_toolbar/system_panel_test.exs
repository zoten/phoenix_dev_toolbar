defmodule PhoenixDevToolbar.SystemPanelTest do
  # The System tab end to end (ADR 11): any process, by name, pid or link,
  # through the panel served by DemoWeb.Endpoint.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers
  import PhoenixDevToolbar.ProcessHelpers

  alias PhoenixDevToolbar.Store

  @endpoint DemoWeb.Endpoint

  setup do
    Store.reset()
    attach_plugins()
    on_exit(fn -> Store.reset() end)
  end

  defp open(conn \\ build_conn()) do
    {_host, sid} = visit("/demo")
    {:ok, panel, _html} = live(conn, "/__pdt/panel?sid=#{sid}")
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
    {:ok, panel, _html} = live(build_conn(), "/__pdt/panel?sid=#{sid}")
    render_hook(panel, "pdt:visibility", %{"open" => true, "visible" => true})

    assert has_element?(panel, "#pdt-process-target-label code")
    refute has_element?(panel, "#pdt-process-target-label button")
    refute has_element?(panel, "#pdt-process-links button")
  end

  test "a process link in the Process tab opens it here" do
    {_host, sid} = visit("/demo")
    {:ok, panel, _html} = live(build_conn(), "/__pdt/panel?sid=#{sid}")
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

      panel |> element("#pdt-system-peek") |> render_click()
      assert has_element?(panel, "#pdt-system-messages-error", "actions: :any")
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
  end
end
