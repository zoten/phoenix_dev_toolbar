defmodule PhoenixDevToolbar.NPlusOnePanelTest do
  # The N+1 detector end to end (ADR 08): a real host LiveView through
  # DemoWeb.Endpoint runs queries, the panel flags repeats in one callback.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

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
    assert has_element?(panel, "#pdt-n-plus-one-0", "SELECT * FROM posts WHERE user_id = $1")
    assert has_element?(panel, "#pdt-n-plus-one-0", "×6")
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
