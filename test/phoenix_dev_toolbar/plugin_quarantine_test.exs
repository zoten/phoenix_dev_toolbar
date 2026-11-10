defmodule PhoenixDevToolbar.PluginQuarantineTest do
  # A plugin that raises is disabled where it raised (host collector, panel
  # summary, panel component) and shown with a Re-enable button; the other
  # tabs keep working. Drives a real host LiveView through DemoWeb.Endpoint.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.TestPlugins.Fragile
  alias PhoenixDevToolbar.TestPlugins.MessageRaisingError
  alias PhoenixDevToolbar.TestPlugins.MountBoom
  alias PhoenixDevToolbar.TestPlugins.TablessFragile

  @endpoint DemoWeb.Endpoint

  setup do
    Store.reset()
    Application.put_env(:phoenix_dev_toolbar, :repos, [DemoWeb.FakeRepo])
    attach_plugins([Fragile])

    on_exit(fn ->
      Application.put_env(:phoenix_dev_toolbar, :repos, [DemoWeb.SQLiteRepo])
      attach_plugins()
      Store.reset()
    end)

    {conn, sid} = load_page("/demo")

    {:ok, host, _html} = live(conn)
    Process.put({:pdt_test_sid, host.pid}, sid)
    {:ok, panel, _html} = live(build_conn(), "/__pdt/panel?sid=#{sid}")
    %{host: host, panel: panel}
  end

  # The flush sends the events to the tab's component with send_update, which
  # lands after the next render call: render twice.
  defp echo(host, panel, value) do
    render_hook(host, "echo", %{"value" => value})
    send(panel.pid, :pdt_flush)
    _ = render(panel)
    _ = render(panel)
  end

  defp sid_of(host), do: Process.get({:pdt_test_sid, host.pid})

  defp still_works(host, panel) do
    render_hook(host, "query", %{"sql" => "SELECT still works"})
    send(panel.pid, :pdt_flush)
    _ = render(panel)
    assert has_element?(panel, "#pdt-queries", "SELECT still works")
  end

  test "a collector that raised: the tab says so, Re-enable brings it back", %{
    host: host,
    panel: panel
  } do
    capture_log(fn -> echo(host, panel, "collect") end)
    echo(host, panel, "ignored while disabled")

    assert has_element?(panel, "#pdt-disabled-fragile", "collect boom")
    assert has_element?(panel, "#pdt-tab-fragile.pdt-tab--error")
    refute has_element?(panel, "#fragile .fragile-value", "ignored while disabled")
    still_works(host, panel)

    panel |> element("#pdt-reenable-fragile") |> render_click()
    refute Collector.quarantined?(Fragile)
    echo(host, panel, "back")

    refute has_element?(panel, "#pdt-disabled-fragile")
    assert has_element?(panel, "#fragile .fragile-value", "back")
  end

  test "a summary that raised disables the plugin in the panel only", %{host: host, panel: panel} do
    echo(host, panel, "one")
    assert has_element?(panel, "#pdt-badge-fragile", "1 fragile")

    log = capture_log(fn -> echo(host, panel, "summary") end)

    assert log =~ "summary boom"
    assert has_element?(panel, "#pdt-disabled-fragile", "summary boom")
    refute has_element?(panel, "#pdt-badge-fragile")
    refute Collector.quarantined?(Fragile)
    still_works(host, panel)
  end

  test "a panel callback or click that raised breaks its tab, not the panel",
       %{host: host, panel: panel} do
    log = capture_log(fn -> echo(host, panel, "panel") end)

    assert log =~ "panel boom"
    _ = render(panel)
    assert has_element?(panel, "#pdt-disabled-fragile", "panel boom")
    refute has_element?(panel, "#fragile")
    still_works(host, panel)

    panel |> element("#pdt-reenable-fragile") |> render_click()
    _ = render(panel)
    assert has_element?(panel, "#fragile")
    refute has_element?(panel, "#pdt-disabled-fragile")

    capture_log(fn -> panel |> element("#fragile-explode") |> render_click() end)
    _ = render(panel)
    assert has_element?(panel, "#pdt-disabled-fragile", "click boom")
    still_works(host, panel)
  end

  test "a render that raised breaks its tab, not the panel", %{host: host, panel: panel} do
    log = capture_log(fn -> echo(host, panel, "render") end)

    assert log =~ "render boom"
    _ = render(panel)
    assert Process.alive?(panel.pid)
    assert has_element?(panel, "#pdt-disabled-fragile", "render boom")
    still_works(host, panel)
  end

  test "a render/1 that raised before its template breaks its tab, not the panel",
       %{host: host, panel: panel} do
    log = capture_log(fn -> echo(host, panel, "eager") end)

    assert log =~ "eager boom"
    _ = render(panel)
    assert has_element?(panel, "#pdt-disabled-fragile", "eager boom")
    still_works(host, panel)
  end

  test "an event recorded under another plugin's id is stamped with its own",
       %{host: host, panel: panel} do
    echo(host, panel, "impostor")

    assert has_element?(panel, "#fragile .fragile-value", "impostor")
    refute has_element?(panel, "#pdt-queries", "impostor")
  end

  test "an async result that raised breaks its tab", %{host: host, panel: panel} do
    capture_log(fn ->
      panel |> element("#fragile-async") |> render_click()
      _ = render_async(panel)
      _ = render(panel)
    end)

    assert has_element?(panel, "#pdt-disabled-fragile", "async boom")
    still_works(host, panel)
  end

  test "badges that raise or are malformed never break the summary bar",
       %{host: host, panel: panel} do
    echo(host, panel, "bad_title")
    refute has_element?(panel, "#pdt-badge-fragile")
    still_works(host, panel)

    capture_log(fn -> echo(host, panel, "badges") end)
    assert has_element?(panel, "#pdt-disabled-fragile", "badges boom")
    still_works(host, panel)
  end

  test "a component mount that raised breaks its tab, not the panel" do
    attach_plugins([MountBoom])

    {_html, log} =
      with_log(fn -> build_conn() |> get("/__pdt/panel?sid=missing") |> html_response(200) end)

    assert log =~ "mount boom"

    capture_log(fn ->
      {:ok, view, _html} = live(build_conn(), "/__pdt/panel?sid=missing")
      _ = render(view)
      assert has_element?(view, "#pdt-disabled-mount_boom", "mount boom")
    end)
  end

  test "a plugin without a tab is shown disabled and re-enabled from its badge",
       %{host: host, panel: _panel} do
    attach_plugins([TablessFragile])
    {:ok, panel, _html} = live(build_conn(), "/__pdt/panel?sid=#{sid_of(host)}")

    capture_log(fn -> echo(host, panel, "tabless") end)

    assert has_element?(panel, "#pdt-badge-disabled-tabless", "Tabless disabled")
    panel |> element("#pdt-badge-disabled-tabless") |> render_click()

    refute Collector.quarantined?(TablessFragile)
    refute has_element?(panel, "#pdt-badge-disabled-tabless")
  end

  test "a banner survives an exception whose message/1 throws" do
    banner = PhoenixDevToolbar.Truncate.banner(:error, %MessageRaisingError{})
    assert banner =~ "MessageRaisingError"
    assert banner =~ "message unavailable"
  end
end
