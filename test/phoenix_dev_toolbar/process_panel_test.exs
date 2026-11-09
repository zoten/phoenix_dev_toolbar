defmodule PhoenixDevToolbar.ProcessPanelTest do
  # The Process tab end to end (ADR 09): a real host LiveView through
  # DemoWeb.Endpoint, read only while the tab is shown and the panel visible.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Panel
  alias PhoenixDevToolbar.Panels
  alias PhoenixDevToolbar.Store

  @endpoint DemoWeb.Endpoint

  setup do
    Store.reset()
    attach_plugins()
    on_exit(fn -> Store.reset() end)
  end

  defp open(sid) do
    {:ok, panel, _html} = live(build_conn(), "/__pdt/panel?sid=#{sid}")
    panel |> element("#pdt-tab-process") |> render_click()
    panel
  end

  defp visible(panel),
    do: render_hook(panel, "pdt:visibility", %{"open" => true, "visible" => true})

  defp hidden(panel),
    do: render_hook(panel, "pdt:visibility", %{"open" => true, "visible" => false})

  defp samples(panel) do
    panel
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#pdt-process-vitals")
    |> LazyHTML.attribute("data-samples")
    |> then(fn [n] -> String.to_integer(n) end)
  end

  # A tick that is not the pending timer (a stale or forged token) is dropped.
  defp stale_tick(panel) do
    Panel.send_now(panel.pid, Panels.Process, "pdt-panel-process", {:sample, make_ref()})
    _ = render(panel)
  end

  # Showing the panel again reads at once.
  defp reshow(panel) do
    hidden(panel)
    visible(panel)
  end

  test "the host LiveView's vital signs and relations, once the panel is visible" do
    {host, sid} = visit("/demo")
    panel = open(sid)

    assert has_element?(panel, "#pdt-process-target-label", "DemoWeb.PageLive")
    refute has_element?(panel, "#pdt-process-vitals")

    visible(panel)

    assert has_element?(panel, "#pdt-process-memory", "B")
    assert has_element?(panel, "#pdt-process-queue", "0")
    assert has_element?(panel, "#pdt-process-details", "waiting")
    assert has_element?(panel, "#pdt-process-links")
    assert has_element?(panel, "#pdt-process-monitored-by")
    _ = host
  end

  test "it samples only while shown and visible, one loop at a time" do
    {_host, sid} = visit("/demo")
    panel = open(sid)
    visible(panel)
    assert samples(panel) == 1
    assert has_element?(panel, "#pdt-process-memory .pdt-vital__peak", "over 1 sample")

    reshow(panel)
    assert samples(panel) == 2
    assert has_element?(panel, "#pdt-process-memory .pdt-vital__peak", "over 2 samples")

    stale_tick(panel)
    assert samples(panel) == 2

    # Another tab selected: nothing is read, even when the panel shows again.
    panel |> element("#pdt-tab-ecto") |> render_click()
    reshow(panel)
    panel |> element("#pdt-tab-process") |> render_click()
    assert samples(panel) == 3
  end

  test "GC now collects the selected process, at most once a second" do
    {host, sid} = visit("/demo")
    panel = open(sid)
    visible(panel)

    # Count the host's real full sweeps (tracing ends with this test process).
    :erlang.trace(host.pid, true, [:garbage_collection])

    panel |> element("#pdt-process-gc") |> render_click()
    _ = render_async(panel)
    assert_receive {:trace, _pid, :gc_major_start, _info}
    assert has_element?(panel, "#pdt-process-gc-result", ~r/freed|nothing to free/)

    # A second click within the second collects nothing, and says why.
    panel |> element("#pdt-process-gc") |> render_click()
    _ = render_async(panel)
    refute_receive {:trace, _pid, :gc_major_start, _info}, 100
    assert has_element?(panel, "#pdt-process-gc-note", "at most one collection a second")
    assert has_element?(panel, "#pdt-process-gc-result", ~r/freed|nothing to free/)
  end

  test "a dead target says so" do
    {host, sid} = visit("/demo")
    panel = open(sid)
    visible(panel)

    # The test is linked to the host LiveView (live/2).
    Process.flag(:trap_exit, true)
    ref = Process.monitor(host.pid)
    Process.exit(host.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}

    reshow(panel)
    refute has_element?(panel, "#pdt-process-vitals")
    assert has_element?(panel, "#pdt-process-none")
  end

  test "Kill ends the page's LiveView after a confirm" do
    {host, sid} = visit("/demo")
    panel = open(sid)
    visible(panel)

    # The test is linked to the host LiveView (live/2).
    Process.flag(:trap_exit, true)
    ref = Process.monitor(host.pid)

    panel |> form("#pdt-process-kill-form", %{"reason" => "shutdown"}) |> render_submit()
    assert has_element?(panel, "#pdt-process-confirm-text", "shutdown")
    refute_received {:DOWN, ^ref, :process, _pid, _reason}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        panel |> element("#pdt-process-confirm") |> render_click()
      end)

    assert_receive {:DOWN, ^ref, :process, _pid, :shutdown}
    assert log =~ "killed"

    reshow(panel)
    refute has_element?(panel, "#pdt-process-vitals")
  end

  # Real timers: the relations tick runs every second here (its minimum).
  defp eventually(fun, tries \\ 40) do
    case fun.() do
      true ->
        true

      false when tries > 0 ->
        receive do
        after
          100 -> eventually(fun, tries - 1)
        end

      false ->
        flunk("condition never met")
    end
  end

  test "after a crash, the rejoined LiveView is sampled again without a reshow" do
    Collector.attach([{PhoenixDevToolbar.Plugins.Process, relations_ms: 1000}])
    on_exit(fn -> attach_plugins() end)

    {host, sid} = visit("/demo")
    panel = open(sid)
    visible(panel)
    assert has_element?(panel, "#pdt-process-vitals")

    {live_sid, _span} = Store.caller(host.pid)
    Process.flag(:trap_exit, true)
    ref = Process.monitor(host.pid)
    Process.exit(host.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}

    # The rejoin: the same LiveView session claimed by a new process.
    rejoined = spawn(fn -> receive(do: (:stop -> :ok)) end)
    on_exit(fn -> send(rejoined, :stop) end)
    Store.claim(live_sid, rejoined, self())

    eventually(fn -> has_element?(panel, "#pdt-process-target-label", inspect(rejoined)) end)
    eventually(fn -> has_element?(panel, "#pdt-process-vitals") end)
  end

  test "a nested LiveView shows up even when the panel was open before it connected" do
    {conn, sid} = load_page("/demo/nested")

    panel = open(sid)
    visible(panel)
    {:ok, _host, _html} = live(conn)
    _ = render(panel)

    reshow(panel)
    assert has_element?(panel, "#pdt-process-target option", "DemoWeb.PageLive (nested)")
  end

  test "a nested LiveView can be picked by index; a tampered index is ignored" do
    {_host, sid} = visit("/demo/nested")
    panel = open(sid)
    visible(panel)

    assert has_element?(panel, "#pdt-process-target option", "DemoWeb.NestedLive")
    assert has_element?(panel, "#pdt-process-target option", "DemoWeb.PageLive (nested)")

    panel |> form("#pdt-process-select", %{"index" => "1"}) |> render_change()
    assert has_element?(panel, "#pdt-process-target option[selected]", "(nested)")

    for index <- ["7", "-1", "x"] do
      panel |> element("#pdt-process-select") |> render_change(%{"index" => index})
    end

    assert has_element?(panel, "#pdt-process-target option[selected]", "(nested)")
  end

  test "a page without a LiveView says so" do
    {_conn, sid} = load_page("/demo")

    panel = open(sid)
    visible(panel)
    assert has_element?(panel, "#pdt-process-none")
  end
end
