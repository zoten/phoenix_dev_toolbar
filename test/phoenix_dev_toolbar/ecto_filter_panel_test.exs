defmodule PhoenixDevToolbar.EctoFilterPanelTest do
  # The Ecto tab's tag filter (ADR 08): view only, hidden tags outlive the page.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers
  import PhoenixDevToolbar.ProcessHelpers
  import PhoenixDevToolbar.ReportFixtures

  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  setup do
    Store.reset()
    on_exit(&Store.reset/0)

    request = session(:request, path: "/demo")
    transport = idle_process()
    live = live_session(request.sid, transport)

    query(live, sql: "SELECT * FROM users")
    query(live, sql: "SELECT * FROM users WHERE id = ?")
    query(live, sql: "SELECT * FROM posts", source: "posts")
    query(live, sql: "SELECT version FROM schema_migrations", source: "schema_migrations")
    query(live, sql: "BEGIN", source: nil)

    %{panel: open_panel(request.sid), live: live, transport: transport}
  end

  defp live_session(parent, transport) do
    Store.new_session(
      Session.new(:live_view, parent: parent, owner: idle_process(), transport: transport)
    )
  end

  defp chip(tag), do: "#pdt-filter-" <> Base.url_encode64(tag, padding: false)

  test "lists the page's tags with counts, all shown", %{panel: panel} do
    assert has_element?(panel, chip("source:users") <> "[aria-pressed=true]", "2")
    assert has_element?(panel, chip("source:posts") <> "[aria-pressed=true]", "1")
    assert has_element?(panel, chip("flag:framework") <> "[aria-pressed=true]")
    assert has_element?(panel, chip("flag:no_source") <> "[aria-pressed=true]")
    assert has_element?(panel, "#pdt-ecto-filter-count", "5 of 5 shown")
    assert length(query_row_seqs(panel)) == 5
  end

  test "a click hides a tag's queries and a second one shows them", %{panel: panel} do
    panel |> element(chip("source:users")) |> render_click()

    assert has_element?(panel, chip("source:users") <> "[aria-pressed=false]")
    assert query_row_seqs(panel, "FROM users") == []
    assert length(query_row_seqs(panel)) == 3
    assert has_element?(panel, "#pdt-ecto-filter-count", "3 of 5 shown")

    panel |> element(chip("source:users")) |> render_click()
    assert length(query_row_seqs(panel, "FROM users")) == 2
    assert has_element?(panel, "#pdt-ecto-filter-count", "5 of 5 shown")
  end

  test "none hides everything, all shows everything", %{panel: panel} do
    panel |> element("#pdt-filter-none") |> render_click()
    assert query_row_seqs(panel) == []
    assert has_element?(panel, "#pdt-ecto-filter-count", "0 of 5 shown")

    panel |> element("#pdt-filter-all") |> render_click()
    assert length(query_row_seqs(panel)) == 5
  end

  test "an unknown or malformed tag is ignored", %{panel: panel} do
    for params <- [%{"tag" => "source:nope"}, %{"tag" => %{"a" => 1}}] do
      panel |> element(chip("source:users")) |> render_click(params)
    end

    assert length(query_row_seqs(panel)) == 5
  end

  test "queries arriving later follow the filter", %{panel: panel, live: live} do
    panel |> element(chip("source:posts")) |> render_click()

    query(live, sql: "SELECT * FROM posts LATER", source: "posts")
    query(live, sql: "SELECT * FROM users LATER")
    flush(panel)

    assert query_row_seqs(panel, "posts LATER") == []
    assert [_seq] = query_row_seqs(panel, "users LATER")
    assert has_element?(panel, "#pdt-ecto-filter-count", "5 of 7 shown")
    assert has_element?(panel, chip("source:posts"), "2")
  end

  test "a hidden tag stays hidden on the next page", %{
    panel: panel,
    live: live,
    transport: transport
  } do
    panel |> element(chip("flag:framework")) |> render_click()

    next = live_session(live.sid, transport)
    query(next, sql: "SELECT version FROM schema_migrations NEXT", source: "schema_migrations")
    query(next, sql: "SELECT * FROM users NEXT")
    Notify.session(next)
    _ = render(panel)

    assert query_row_seqs(panel, "schema_migrations NEXT") == []
    assert [_seq] = query_row_seqs(panel, "users NEXT")
    assert has_element?(panel, chip("flag:framework") <> "[aria-pressed=false]")
  end

  test "a row's open details survive a filter change", %{panel: panel} do
    [seq] = query_row_seqs(panel, "FROM posts")
    panel |> element("#pdt-details-toggle-#{seq}") |> render_click()

    panel |> element(chip("source:users")) |> render_click()

    assert has_element?(panel, "#pdt-details-toggle-#{seq}[aria-expanded=true]")
  end
end
