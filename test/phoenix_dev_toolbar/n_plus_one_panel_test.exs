defmodule PhoenixDevToolbar.NPlusOnePanelTest do
  # The N+1 detector end to end (ADR 08): a real host LiveView through
  # DemoWeb.Endpoint runs queries, the panel flags repeats in one callback.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.EnvHelpers
  import PhoenixDevToolbar.PageHelpers
  import PhoenixDevToolbar.ReportFixtures, only: [query: 2, session: 2]

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Plugins
  alias PhoenixDevToolbar.Store

  @endpoint DemoWeb.Endpoint

  defp start(plugins) do
    Store.reset()

    # Registered before the env change: runs after it is restored.
    on_exit(fn ->
      attach_plugins()
      Store.reset()
    end)

    put_app_env(:repos, [DemoWeb.FakeRepo])
    Collector.attach(plugins)

    {conn, sid} = load_page("/demo")

    {:ok, host, _html} = live(conn)
    panel = open_panel(sid)
    {host, panel}
  end

  # Tab deliveries land after the next render: render twice.
  defp settle(panel) do
    _ = flush(panel)
    _ = render(panel)
  end

  test "five identical queries in one callback are an N+1: badge, group and tagged row" do
    {host, panel} = start(PhoenixDevToolbar.Application.plugins())

    render_hook(host, "queries", %{
      "sql" => "SELECT * FROM posts WHERE user_id = $1",
      "count" => 6
    })

    settle(panel)

    assert has_element?(panel, "#pdt-badge-ecto-n-plus-one", "N+1 ×1")
    assert has_element?(panel, "#pdt-n-plus-one li", "SELECT * FROM posts WHERE user_id = $1")
    assert has_element?(panel, "#pdt-n-plus-one li", "×6")
    # The raw values for agents (ADR 14).
    assert has_element?(
             panel,
             ~s(#pdt-n-plus-one li[data-pdt-row="n-plus-one"][data-pdt-count="6"][data-pdt-callbacks="1"])
           )

    assert has_element?(panel, ~s(#pdt-queries [data-pdt-row="query"][data-pdt-n-plus-one]))
    # Rows from the threshold on (the 5th and 6th) are tagged.
    tags =
      panel
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#pdt-queries .pdt-tag--warn")

    assert Enum.count(tags) == 2
    # FakeRepo queries have no stacktrace: the hint explains the coarser grouping.
    assert has_element?(panel, "#pdt-n-plus-one-hint")
  end

  test "with origins, two call sites are two groups and no hint is shown" do
    {host, panel} = start(PhoenixDevToolbar.Application.plugins())

    for file <- ["lib/a.ex", "lib/b.ex"],
        do: render_hook(host, "queries", %{"sql" => "SELECT u", "count" => 5, "origin" => file})

    settle(panel)

    assert has_element?(panel, "#pdt-badge-ecto-n-plus-one", "N+1 ×2")
    assert has_element?(panel, "#pdt-n-plus-one li .pdt-origin", "lib/a.ex:3")
    assert has_element?(panel, "#pdt-n-plus-one li .pdt-origin", "lib/b.ex:3")
    refute has_element?(panel, "#pdt-n-plus-one-hint")
  end

  test "repeats in later callbacks join the group; Clear empties the list and the badge" do
    {host, panel} = start(PhoenixDevToolbar.Application.plugins())

    for _click <- 1..2, do: render_hook(host, "queries", %{"sql" => "SELECT r", "count" => 5})
    settle(panel)

    assert has_element?(panel, "#pdt-badge-ecto-n-plus-one", "N+1 ×1")
    assert has_element?(panel, "#pdt-n-plus-one li", "in 2 callbacks")

    panel |> element("#pdt-n-plus-one-clear") |> render_click()
    settle(panel)

    refute has_element?(panel, "#pdt-badge-ecto-n-plus-one")
    refute has_element?(panel, "#pdt-n-plus-one")

    # Still there after a fix? It comes back on the next repeat.
    render_hook(host, "queries", %{"sql" => "SELECT r", "count" => 5})
    settle(panel)
    assert has_element?(panel, "#pdt-n-plus-one li", "in 1 callback")
  end

  test "the same query once per callback, five times, is not an N+1" do
    {host, panel} = start(PhoenixDevToolbar.Application.plugins())

    for _click <- 1..5, do: render_hook(host, "queries", %{"sql" => "SELECT 1", "count" => 1})
    settle(panel)

    assert has_element?(panel, "#pdt-badge-ecto-queries", "5 queries")
    refute has_element?(panel, "#pdt-badge-ecto-n-plus-one")
    refute has_element?(panel, "#pdt-n-plus-one")
  end

  test "the threshold comes from the plugin's n_plus_one option; false disables it" do
    {host, panel} = start([{Plugins.Ecto, n_plus_one: 2}, Plugins.LiveView])
    render_hook(host, "queries", %{"sql" => "SELECT 2", "count" => 2})
    settle(panel)
    assert has_element?(panel, "#pdt-badge-ecto-n-plus-one")

    {host, panel} = start([{Plugins.Ecto, n_plus_one: false}, Plugins.LiveView])
    render_hook(host, "queries", %{"sql" => "SELECT 3", "count" => 9})
    settle(panel)
    refute has_element?(panel, "#pdt-badge-ecto-n-plus-one")
    refute has_element?(panel, "#pdt-n-plus-one")
  end

  test "opening the stale Ecto tab before the pending flush does not count queries twice" do
    Store.reset()
    on_exit(&Store.reset/0)
    request = session(:request, path: "/demo")
    live = session(:live_view, parent: request.sid, path: "/demo", view: DemoWeb.PageLive)
    panel = open_panel(request.sid)
    open_panel_tab(panel, "live_view")

    # 1 query, flushed; 2 more stay pending: 3 identical queries in one span,
    # below the threshold (5)
    query(live, span: 7)
    flush(panel)
    for _ <- 1..2, do: query(live, span: 7)

    # the two unflushed queries must reach the tab once, through the flush
    open_panel_tab(panel, "ecto")
    flush(panel)
    # Tab deliveries land after the next render.
    _ = render(panel)

    # Exactly the 3 queries, each once: the badge and the rows agree.
    assert has_element?(panel, "#pdt-badge-ecto-queries", "3 queries")

    assert panel
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#pdt-queries li.pdt-row")
           |> Enum.count() == 3

    refute has_element?(panel, "#pdt-n-plus-one")

    # The detector still counts: two more make a group of exactly 5.
    for _ <- 1..2, do: query(live, span: 7)
    flush(panel)
    _ = render(panel)
    assert has_element?(panel, "#pdt-badge-ecto-n-plus-one", "N+1 ×1")
    assert has_element?(panel, ~s(#pdt-n-plus-one li[data-pdt-count="5"]))
  end
end
