defmodule PhoenixDevToolbar.ProcessPanelTest do
  # The Process tab end to end (ADR 09): a real host LiveView through
  # DemoWeb.Endpoint, read only while the tab is shown and the panel visible.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Panel
  alias PhoenixDevToolbar.Panels
  alias PhoenixDevToolbar.Store

  @endpoint DemoWeb.Endpoint

  setup do
    Store.reset()
    Collector.attach(PhoenixDevToolbar.Application.plugins())
    on_exit(fn -> Store.reset() end)
  end

  defp visit(path) do
    conn =
      build_conn()
      |> Plug.Conn.put_req_header("accept", "text/html")
      |> Plug.Conn.put_req_header("sec-fetch-dest", "document")
      |> get(path)

    [sid] =
      conn
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("script[data-pdt-sid]")
      |> LazyHTML.attribute("data-pdt-sid")

    {:ok, host, _html} = live(conn)
    {host, sid}
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

  defp tick(panel, host_pid) do
    Panel.send_now(panel.pid, Panels.Process, "pdt-panel-process", {:sample, host_pid})
    _ = render(panel)
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

  test "it samples only while shown and visible" do
    {host, sid} = visit("/demo")
    panel = open(sid)
    visible(panel)
    assert samples(panel) == 1

    tick(panel, host.pid)
    assert samples(panel) == 2

    hidden(panel)
    tick(panel, host.pid)
    assert samples(panel) == 2

    panel |> element("#pdt-tab-ecto") |> render_click()
    visible(panel)
    tick(panel, host.pid)
    refute has_element?(panel, "#pdt-process-vitals[data-samples='3']")
  end

  test "a read for another process (an older target) is ignored" do
    {_host, sid} = visit("/demo")
    panel = open(sid)
    visible(panel)

    tick(panel, spawn(fn -> :ok end))
    assert samples(panel) == 1
  end

  test "a nested LiveView can be picked by index; a tampered index is ignored" do
    {_host, sid} = visit("/demo/nested")
    panel = open(sid)
    visible(panel)

    assert has_element?(panel, "#pdt-process-target option", "DemoWeb.NestedLive")
    assert has_element?(panel, "#pdt-process-target option", "nested LiveView")

    panel |> form("#pdt-process-select", %{"index" => "1"}) |> render_change()
    assert has_element?(panel, "#pdt-process-target option[selected]", "nested LiveView")

    for index <- ["7", "-1", "x"] do
      panel |> element("#pdt-process-select") |> render_change(%{"index" => index})
    end

    assert has_element?(panel, "#pdt-process-target option[selected]", "nested LiveView")
  end

  test "a page without a LiveView says so" do
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

    panel = open(sid)
    visible(panel)
    assert has_element?(panel, "#pdt-process-none")
  end
end
