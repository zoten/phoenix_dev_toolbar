defmodule PhoenixDevToolbar.PluginQuarantineTest do
  # A plugin that raises is disabled where it raised (host collector, panel
  # summary, panel component) and shown with a Re-enable button; the other
  # tabs keep working. Drives a real host LiveView through DemoWeb.Endpoint.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.TestPlugins.Fragile

  @endpoint DemoWeb.Endpoint

  setup do
    Store.reset()
    Application.put_env(:phoenix_dev_toolbar, :repos, [DemoWeb.FakeRepo])
    Collector.attach(PhoenixDevToolbar.Application.plugins() ++ [Fragile])

    on_exit(fn ->
      Application.delete_env(:phoenix_dev_toolbar, :repos)
      Collector.attach(PhoenixDevToolbar.Application.plugins())
      Store.reset()
    end)

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

    {:ok, host, _html} = live(conn)
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
end
