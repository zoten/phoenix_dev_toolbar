defmodule PhoenixDevToolbar.PluginPanelTest do
  # A plugin's tab end to end: a real host LiveView through DemoWeb.Endpoint
  # emits telemetry, the plugin collects it, the panel shows its tab and badge.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.TestPlugins.BadgeOnly
  alias PhoenixDevToolbar.TestPlugins.Tabbed

  @endpoint DemoWeb.Endpoint

  setup do
    Store.reset()
    Collector.attach(PhoenixDevToolbar.Application.plugins() ++ [{Tabbed, prefix: "echo"}])

    on_exit(fn ->
      Collector.attach(PhoenixDevToolbar.Application.plugins())
      Store.reset()
    end)
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

  defp props(panel) do
    panel
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#tabbed")
    |> LazyHTML.attribute("data-props")
    |> then(fn [value] -> String.to_integer(value) end)
  end

  defp flush(panel) do
    send(panel.pid, :pdt_flush)
    _ = render(panel)
  end

  test "a plugin gets its own tab and badge, live, with its config" do
    {host, sid} = visit("/demo")
    {:ok, panel, _html} = live(build_conn(), "/__pdt/panel?sid=#{sid}")

    assert has_element?(panel, "#pdt-tab-tabbed", "Tabbed")
    assert has_element?(panel, "#tabbed[data-prefix=echo][data-shown=false]")

    render_hook(host, "echo", %{"value" => "one"})
    render_hook(host, "echo", %{"value" => "two"})
    flush(panel)

    assert has_element?(panel, "#tabbed-list li", "echo one")
    assert has_element?(panel, "#tabbed-list li", "echo two")
    assert has_element?(panel, "#pdt-badge-tabbed", "2 echoes")

    # handle_props/1 runs on a real change only, not on every parent render.
    props = props(panel)
    panel |> element("#pdt-tab-request") |> render_click()
    assert props(panel) == props

    panel |> element("#pdt-tab-tabbed") |> render_click()
    assert has_element?(panel, "#tabbed[data-shown=true]")
    assert props(panel) == props + 1
    refute has_element?(panel, "#pdt-section-tabbed[hidden]")
  end

  test "badges follow the configuration order; a plugin without a panel has no tab" do
    Collector.attach(PhoenixDevToolbar.Application.plugins() ++ [BadgeOnly, {Tabbed, []}])
    {host, sid} = visit("/demo")
    render_hook(host, "echo", %{"value" => "x"})
    {:ok, panel, _html} = live(build_conn(), "/__pdt/panel?sid=#{sid}")

    ids =
      panel
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#pdt-summary .pdt-badge")
      |> LazyHTML.attribute("id")

    assert ids == [
             "pdt-badge-queries",
             "pdt-badge-response",
             "pdt-badge-live",
             "pdt-badge-badge_only",
             "pdt-badge-tabbed"
           ]

    assert has_element?(panel, "#pdt-badge-badge_only.pdt-badge--warn", "1 seen")
    refute has_element?(panel, "#pdt-tab-badge_only")
  end

  test "live navigation resets the tab to the new page" do
    {host, sid} = visit("/demo")
    {:ok, panel, _html} = live(build_conn(), "/__pdt/panel?sid=#{sid}")

    render_hook(host, "echo", %{"value" => "before"})
    flush(panel)
    assert has_element?(panel, "#tabbed-list li", "echo before")

    {:ok, next, _html} = live_redirect(host, to: "/demo/other")
    _ = render(panel)
    render_hook(next, "echo", %{"value" => "after"})
    flush(panel)

    assert has_element?(panel, "#tabbed-list li", "echo after")
    refute has_element?(panel, "#tabbed-list li", "echo before")
    assert has_element?(panel, "#pdt-badge-tabbed", "1 echoes")
  end

  test "a tab says how many of its plugin's events were trimmed" do
    Store.put_limits(max_events: 2)
    {host, sid} = visit("/demo")
    for n <- 1..5, do: render_hook(host, "echo", %{"value" => "#{n}"})
    _ = :sys.get_state(Store)

    {:ok, panel, _html} = live(build_conn(), "/__pdt/panel?sid=#{sid}")

    assert has_element?(panel, "#pdt-trimmed-tabbed", "3 older events trimmed")
    refute has_element?(panel, "#pdt-trimmed-ecto")
  end
end
