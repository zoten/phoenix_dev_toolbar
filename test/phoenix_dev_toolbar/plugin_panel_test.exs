defmodule PhoenixDevToolbar.PluginPanelTest do
  # A plugin's tab end to end: a real host LiveView through DemoWeb.Endpoint
  # emits telemetry, the plugin collects it, the panel shows its tab and badge.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers

  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.TestPlugins.BadgeOnly
  alias PhoenixDevToolbar.TestPlugins.Tabbed

  setup do
    Store.reset()
    attach_plugins([{Tabbed, prefix: "echo"}])

    on_exit(fn ->
      attach_plugins()
      Store.reset()
    end)
  end

  defp props(panel) do
    panel
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#tabbed")
    |> LazyHTML.attribute("data-props")
    |> then(fn [value] -> String.to_integer(value) end)
  end

  test "Panel.navigate/3 shows the target tab and hands it the params" do
    {_host, sid} = visit("/demo")
    panel = open_panel(sid)
    assert has_element?(panel, "#tabbed[data-shown=false]")

    panel |> element("#tabbed-go-missing") |> render_click()
    assert has_element?(panel, "#tabbed[data-shown=false][data-navigated='']")

    panel |> element("#tabbed-go-self") |> render_click()
    assert has_element?(panel, "#tabbed[data-shown=true][data-navigated=tabbed]")
  end

  test "a tab opened after missing events gets them all through handle_reset" do
    {host, sid} = visit("/demo")
    panel = open_panel(sid)

    render_hook(host, "echo", %{"value" => "one"})
    render_hook(host, "echo", %{"value" => "two"})
    flush(panel)
    refute has_element?(panel, "#tabbed-list li")

    open_panel_tab(panel, "tabbed")

    assert has_element?(panel, "#tabbed-list li", "echo one")
    assert has_element?(panel, "#tabbed-list li", "echo two")
  end

  test "Panel.navigate/3 outside the panel (a host LiveView) does nothing" do
    socket = %Phoenix.LiveView.Socket{view: DemoWeb.PageLive}

    assert PhoenixDevToolbar.Panel.navigate(socket, :tabbed, %{"via" => "host"}) == socket
    refute_received {:pdt_navigate, _tab, _params}
  end

  test "a plugin gets its own tab and badge, live, with its config" do
    {host, sid} = visit("/demo")
    panel = open_panel(sid)

    assert has_element?(panel, "#pdt-tab-tabbed", "Tabbed")
    assert has_element?(panel, "#tabbed[data-prefix=echo][data-shown=false]")

    open_panel_tab(panel, "tabbed")
    render_hook(host, "echo", %{"value" => "one"})
    render_hook(host, "echo", %{"value" => "two"})
    flush(panel)

    assert has_element?(panel, "#tabbed-list li", "echo one")
    assert has_element?(panel, "#tabbed-list li", "echo two")
    assert has_element?(panel, "#pdt-badge-tabbed", "2 echoes")

    # handle_props/1 runs on a real change only, not on every parent render.
    panel |> element("#pdt-tab-request") |> render_click()
    props = props(panel)
    _ = render(panel)
    assert props(panel) == props

    panel |> element("#pdt-tab-tabbed") |> render_click()
    assert has_element?(panel, "#tabbed[data-shown=true]")
    assert props(panel) == props + 1
    refute has_element?(panel, "#pdt-section-tabbed[hidden]")
  end

  test "badges follow the configuration order; a plugin without a panel has no tab" do
    attach_plugins([BadgeOnly, {Tabbed, []}])
    {host, sid} = visit("/demo")
    render_hook(host, "echo", %{"value" => "x"})
    panel = open_panel(sid)

    ids =
      panel
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#pdt-summary .pdt-badge")
      |> LazyHTML.attribute("id")

    assert ids == [
             "pdt-badge-ecto-queries",
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
    panel = open_panel(sid)
    open_panel_tab(panel, "tabbed")

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

    panel = open_panel(sid)

    assert has_element?(panel, "#pdt-trimmed-tabbed", "3 older events trimmed")
    refute has_element?(panel, "#pdt-trimmed-ecto")
  end

  # A memory bound (ADR 03): the panel remembers the seqs it showed only within
  # each sid's re-read window, even when the page's request sid stays quiet.
  test "a long lived page keeps the panel's seen seqs bounded per sid" do
    Store.put_limits(events_per_second: 10_000)
    {host, sid} = visit("/demo")
    panel = open_panel(sid)
    open_panel_tab(panel, "tabbed")

    for batch <- 1..20 do
      for n <- 1..10, do: render_hook(host, "echo", %{"value" => "#{batch}-#{n}"})
      flush(panel)
    end

    _ = render(panel)
    assert has_element?(panel, "#tabbed-list li", "echo 20-10")
    %{socket: %{assigns: %{seen: seen}}} = :sys.get_state(panel.pid)
    # 400 events shown; each sid keeps its re-read window (64 seqs) plus the
    # last flush's events (20).
    assert seen |> Map.values() |> Enum.map(&MapSet.size/1) |> Enum.max() <= 64 + 20 + 1
  end
end
