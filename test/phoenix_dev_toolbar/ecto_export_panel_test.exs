defmodule PhoenixDevToolbar.EctoExportPanelTest do
  # The Ecto tab's export end to end (ADR 08): a real host LiveView runs real
  # SQLite queries, the tab's form pushes the JSON payload to its hook.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers

  setup :sqlite_panel

  defp run(host, panel, sql, params) do
    render_hook(host, "sqlite", %{"sql" => sql, "params" => params})
    send(panel.pid, :pdt_flush)
    _ = render(panel)
  end

  defp export(panel, fields, button) do
    panel
    |> form("#pdt-ecto-export", fields)
    |> put_submitter(button)
    |> render_submit()

    render_async(panel)
  end

  test "no queries, no export form", %{panel: panel} do
    refute has_element?(panel, "#pdt-ecto-export")
  end

  test "short export downloads sql, params and location", %{host: host, panel: panel} do
    run(host, panel, "SELECT * FROM users WHERE id = ?", [1])

    export(panel, %{"format" => "short"}, "#pdt-export-download")

    assert_push_event(panel, "pdt:export", %{
      action: "download",
      filename: "ecto-queries-short-" <> _rest,
      payload: %{"format" => "short", "queries" => queries}
    })

    assert [%{"sql" => "SELECT * FROM users WHERE id = ?", "params" => "[1]"} = row] =
             Enum.filter(queries, &(&1["sql"] =~ "users"))

    assert Map.keys(row) |> Enum.sort() == ~w(location params seq sql)
  end

  test "full export with EXPLAIN copies the plans", %{host: host, panel: panel} do
    run(host, panel, "SELECT * FROM users WHERE id = ?", [1])
    run(host, panel, "UPDATE users SET name = name WHERE id = ?", [1])

    export(panel, %{"format" => "full", "explain" => "true"}, "#pdt-export-copy")

    assert_push_event(panel, "pdt:export", %{action: "copy", payload: %{"queries" => queries}})

    select = Enum.find(queries, &(&1["sql"] == "SELECT * FROM users WHERE id = ?"))
    update = Enum.find(queries, &(&1["sql"] =~ "UPDATE users"))

    assert %{"status" => "ok", "plan" => plan} = select["explain"]
    assert plan =~ "SEARCH users USING INTEGER PRIMARY KEY"
    assert %{"status" => "not_explainable"} = update["explain"]
    assert %{"phase" => "live", "repo" => "DemoWeb.SQLiteRepo"} = select
  end

  test "the chosen format and EXPLAIN survive an export", %{host: host, panel: panel} do
    run(host, panel, "SELECT id FROM users", [])
    choice = %{"format" => "full", "explain" => "true"}

    panel |> form("#pdt-ecto-export", choice) |> render_change()
    export(panel, choice, "#pdt-export-download")
    assert_push_event(panel, "pdt:export", %{})

    assert has_element?(panel, "#pdt-export-full[checked]")
    assert has_element?(panel, "#pdt-export-explain[checked]")
    refute has_element?(panel, "#pdt-export-short[checked]")

    panel |> form("#pdt-ecto-export", %{"format" => "short"}) |> render_change()
    assert has_element?(panel, "#pdt-export-short[checked]")
    refute has_element?(panel, "#pdt-export-full[checked]")
  end

  test "full export without EXPLAIN runs none", %{host: host, panel: panel} do
    run(host, panel, "SELECT id FROM users", [])

    export(panel, %{"format" => "full"}, "#pdt-export-download")

    assert_push_event(panel, "pdt:export", %{payload: %{"queries" => [_ | _] = queries}})
    assert Enum.all?(queries, &(&1["explain"] == %{"status" => "not_requested"}))
  end

  test "tampered submits are ignored, never break the tab", %{host: host, panel: panel} do
    run(host, panel, "SELECT id FROM users", [])

    for params <- [
          %{"format" => "xml", "action" => "download"},
          %{"format" => "short", "action" => "email"},
          %{"format" => %{"a" => 1}}
        ] do
      panel |> element("#pdt-ecto-export") |> render_submit(params)
    end

    render_async(panel)
    refute_push_event(panel, "pdt:export", %{}, 50)
    refute has_element?(panel, "#pdt-disabled-ecto")
    assert has_element?(panel, "#pdt-ecto-export")
  end
end
