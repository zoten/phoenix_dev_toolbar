defmodule PhoenixDevToolbar.NPlusOnePanelTest do
  # The N+1 detector end to end (ADR 08): a real host LiveView through
  # DemoWeb.Endpoint runs queries, the panel flags repeats in one callback.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Plugins
  alias PhoenixDevToolbar.Store

  @endpoint DemoWeb.Endpoint

  defp start(plugins) do
    Store.reset()
    Application.put_env(:phoenix_dev_toolbar, :repos, [DemoWeb.FakeRepo])
    Collector.attach(plugins)

    on_exit(fn ->
      Application.delete_env(:phoenix_dev_toolbar, :repos)
      attach_plugins()
      Store.reset()
    end)

    {conn, sid} = load_page("/demo")

    {:ok, host, _html} = live(conn)
    {:ok, panel, _html} = live(build_conn(), "/__pdt/panel?sid=#{sid}")
    {host, panel}
  end

  # Tab deliveries land after the next render: render twice.
  defp flush(panel) do
    send(panel.pid, :pdt_flush)
    _ = render(panel)
    _ = render(panel)
  end

  test "five identical queries in one callback are an N+1: badge, group and tagged row" do
    {host, panel} = start(PhoenixDevToolbar.Application.plugins())

    render_hook(host, "queries", %{
      "sql" => "SELECT * FROM posts WHERE user_id = $1",
      "count" => 6
    })

    flush(panel)

    assert has_element?(panel, "#pdt-badge-ecto-n-plus-one", "N+1 ×1")
    assert has_element?(panel, "#pdt-n-plus-one li", "SELECT * FROM posts WHERE user_id = $1")
    assert has_element?(panel, "#pdt-n-plus-one li", "×6")
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

    flush(panel)

    assert has_element?(panel, "#pdt-badge-ecto-n-plus-one", "N+1 ×2")
    assert has_element?(panel, "#pdt-n-plus-one li .pdt-origin", "lib/a.ex:3")
    assert has_element?(panel, "#pdt-n-plus-one li .pdt-origin", "lib/b.ex:3")
    refute has_element?(panel, "#pdt-n-plus-one-hint")
  end

  test "repeats in later callbacks join the group; Clear empties the list and the badge" do
    {host, panel} = start(PhoenixDevToolbar.Application.plugins())

    for _click <- 1..2, do: render_hook(host, "queries", %{"sql" => "SELECT r", "count" => 5})
    flush(panel)

    assert has_element?(panel, "#pdt-badge-ecto-n-plus-one", "N+1 ×1")
    assert has_element?(panel, "#pdt-n-plus-one li", "in 2 callbacks")

    panel |> element("#pdt-n-plus-one-clear") |> render_click()
    flush(panel)

    refute has_element?(panel, "#pdt-badge-ecto-n-plus-one")
    refute has_element?(panel, "#pdt-n-plus-one")

    # Still there after a fix? It comes back on the next repeat.
    render_hook(host, "queries", %{"sql" => "SELECT r", "count" => 5})
    flush(panel)
    assert has_element?(panel, "#pdt-n-plus-one li", "in 1 callback")
  end

  test "the same query once per callback, five times, is not an N+1" do
    {host, panel} = start(PhoenixDevToolbar.Application.plugins())

    for _click <- 1..5, do: render_hook(host, "queries", %{"sql" => "SELECT 1", "count" => 1})
    flush(panel)

    assert has_element?(panel, "#pdt-badge-ecto-queries", "5 queries")
    refute has_element?(panel, "#pdt-badge-ecto-n-plus-one")
    refute has_element?(panel, "#pdt-n-plus-one")
  end

  test "the threshold comes from the plugin's n_plus_one option; false disables it" do
    {host, panel} = start([{Plugins.Ecto, n_plus_one: 2}, Plugins.LiveView])
    render_hook(host, "queries", %{"sql" => "SELECT 2", "count" => 2})
    flush(panel)
    assert has_element?(panel, "#pdt-badge-ecto-n-plus-one")

    {host, panel} = start([{Plugins.Ecto, n_plus_one: false}, Plugins.LiveView])
    render_hook(host, "queries", %{"sql" => "SELECT 3", "count" => 9})
    flush(panel)
    refute has_element?(panel, "#pdt-badge-ecto-n-plus-one")
    refute has_element?(panel, "#pdt-n-plus-one")
  end
end
