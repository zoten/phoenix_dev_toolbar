defmodule PhoenixDevToolbar.ExplainPanelTest do
  # EXPLAIN end to end (ADR 08): a real host LiveView through DemoWeb.Endpoint
  # runs real SQLite queries; the Ecto tab explains them on click.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers

  setup :sqlite_panel

  # Runs `sql` in the host LiveView; returns the seq of its row in the panel.
  defp run(host, panel, sql, params \\ []) do
    render_hook(host, "sqlite", %{"sql" => sql, "params" => params})
    _ = flush(panel)

    [id] =
      panel
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#pdt-queries li.pdt-row")
      |> Enum.filter(&(LazyHTML.text(&1) =~ sql))
      |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

    "pdt-query-" <> seq = id
    seq
  end

  test "a SELECT is explained under its row", %{host: host, panel: panel} do
    seq = run(host, panel, "SELECT * FROM users WHERE id = ?", [1])

    panel |> element("#pdt-explain-#{seq}") |> render_click()
    render_async(panel)

    assert has_element?(panel, "#pdt-plan-#{seq}", "SEARCH users USING INTEGER PRIMARY KEY")
    assert has_element?(panel, ~s|#pdt-explain-#{seq}[aria-label="EXPLAIN query #{seq}"]|)

    panel |> element("#pdt-plan-hide-#{seq}") |> render_click()
    refute has_element?(panel, "#pdt-plan-#{seq}")
    assert has_element?(panel, "#pdt-explain-#{seq}", "EXPLAIN")
  end

  test "a plan survives opening and closing the row's details", %{host: host, panel: panel} do
    seq = run(host, panel, "SELECT * FROM users WHERE id = ?", [1])
    panel |> element("#pdt-explain-#{seq}") |> render_click()
    render_async(panel)

    panel |> element("#pdt-details-toggle-#{seq}") |> render_click()
    assert has_element?(panel, "#pdt-plan-#{seq}", "SEARCH users")
    panel |> element("#pdt-details-toggle-#{seq}") |> render_click()
    assert has_element?(panel, "#pdt-plan-#{seq}", "SEARCH users")
  end

  test "a query that failed has no button and says why", %{host: host, panel: panel} do
    seq = run(host, panel, "SELECT * FROM no_such_table")

    refute has_element?(panel, "#pdt-explain-#{seq}")
    panel |> element("#pdt-details-toggle-#{seq}") |> render_click()
    assert has_element?(panel, "#pdt-query-#{seq} .pdt-details", "the query itself failed")
  end

  test "malformed clicks are ignored, never break the tab", %{host: host, panel: panel} do
    seq = run(host, panel, "SELECT id FROM users")

    for params <- [%{"seq" => "x"}, %{"seq" => %{"a" => 1}}, %{"seq" => "1.5"}] do
      panel |> element("#pdt-explain-#{seq}") |> render_click(params)
    end

    render_async(panel)
    refute has_element?(panel, "#pdt-disabled-ecto")
    refute has_element?(panel, "#pdt-plan-#{seq}")

    # The tab still works: a real click explains the query.
    panel |> element("#pdt-explain-#{seq}") |> render_click()
    render_async(panel)
    assert has_element?(panel, "#pdt-plan-#{seq}", "SCAN users")
  end

  test "a write has no button and says why", %{host: host, panel: panel} do
    seq = run(host, panel, "UPDATE users SET name = name WHERE id = ?", [1])

    refute has_element?(panel, "#pdt-explain-#{seq}")
    panel |> element("#pdt-details-toggle-#{seq}") |> render_click()

    assert has_element?(
             panel,
             "#pdt-query-#{seq} .pdt-details",
             "only SELECT queries are explained"
           )
  end

  test "a seq of another page is never explained", %{host: host, panel: panel} do
    own = run(host, panel, "SELECT id FROM users")

    {other_host, other_sid} = visit("/demo")
    other_panel = open_panel(other_sid)
    other = run(other_host, other_panel, "SELECT name FROM users")

    # A tampered client: this page's button, another page's seq.
    panel |> element("#pdt-explain-#{own}") |> render_click(%{"seq" => other})
    render_async(panel)

    refute has_element?(panel, "#pdt-plan-#{other}")
    refute has_element?(panel, "#pdt-plan-#{own}")
    refute render(panel) =~ "SCAN users"

    # The tab still works: the page's own seq is explained.
    panel |> element("#pdt-explain-#{own}") |> render_click()
    render_async(panel)
    assert has_element?(panel, "#pdt-plan-#{own}", "SCAN users")
    refute has_element?(panel, "#pdt-plan-#{other}")
  end
end
