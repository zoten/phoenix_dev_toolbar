defmodule PhoenixDevToolbar.EctoExportTest do
  # The Ecto tab's JSON export (ADR 08): pure, from events to a JSON-ready map.
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.EctoExport
  alias PhoenixDevToolbar.Event

  @root "root-sid"

  defp query(seq, opts \\ []) do
    %Event{
      plugin: :ecto,
      kind: :query,
      at: 1_700_000_000_000_000 + seq,
      sid: Keyword.get(opts, :sid, @root),
      span: Keyword.get(opts, :span, 1),
      seq: seq,
      duration: 120,
      data: %{
        repo: DemoWeb.SQLiteRepo,
        sql: Keyword.get(opts, :sql, "SELECT * FROM users WHERE id = ?"),
        params: "[1]",
        source: "users",
        result: Keyword.get(opts, :result, {:ok, 1}),
        times: %{query_time: 100, queue_time: 20},
        stacktrace: ["lib/app.ex:10: App.list/0", "lib/app.ex:2: App.run/0"],
        caller?: false,
        explain: Keyword.get(opts, :explain, {:ok, ["raw-secret-param"]})
      }
    }
  end

  defp build(events, format, opts \\ []) do
    EctoExport.build(events, format, Keyword.merge([root: @root, path: "/demo"], opts))
  end

  # Every value is something JSON encodes as is: no tuples, atoms, pids.
  defp json_safe?(value) when is_map(value),
    do: Enum.all?(value, fn {key, val} -> is_binary(key) and json_safe?(val) end)

  defp json_safe?(value) when is_list(value), do: Enum.all?(value, &json_safe?/1)
  defp json_safe?(value) when is_binary(value) or is_number(value), do: true
  defp json_safe?(value) when is_boolean(value) or is_nil(value), do: true
  defp json_safe?(_value), do: false

  test "short: sql, params and location per query, oldest first" do
    export = build([query(2), query(1)], :short)

    assert %{"format" => "short", "path" => "/demo", "count" => 2, "exported_at" => at} = export
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(at)

    assert [first, %{"seq" => 2}] = export["queries"]

    assert first == %{
             "seq" => 1,
             "sql" => "SELECT * FROM users WHERE id = ?",
             "params" => "[1]",
             "location" => "lib/app.ex:10: App.list/0"
           }

    assert json_safe?(export)
  end

  test "full: every captured detail, JSON safe, raw explain params never included" do
    live = query(2, sid: "live-sid", result: {:error, "no such table"})
    export = build([query(1), live, Event.new(:ecto, :other, %{})], :full)

    assert export["count"] == 2
    assert [http, failed] = export["queries"]

    assert %{
             "phase" => "http",
             "repo" => "DemoWeb.SQLiteRepo",
             "source" => "users",
             "result" => %{"ok" => 1},
             "duration_us" => 120,
             "times" => %{"query_time" => 100, "queue_time" => 20},
             "caller" => false,
             "n_plus_one" => false,
             "stacktrace" => ["lib/app.ex:10: App.list/0", "lib/app.ex:2: App.run/0"],
             "explain" => %{"status" => "not_requested"}
           } = http

    assert {:ok, _datetime, 0} = DateTime.from_iso8601(http["at"])
    assert %{"phase" => "live", "result" => %{"error" => "no such table"}} = failed

    assert json_safe?(export)
    refute inspect(export) =~ "raw-secret-param"
  end

  test "full: rows from the N+1 threshold on are flagged, a Clear starts over" do
    cleared = %{Event.new(:ecto, :n_plus_one_cleared, %{}) | sid: @root, seq: 4}
    events = [query(1), query(2), query(3), cleared, query(5)]

    flags = build(events, :full, threshold: 2)["queries"] |> Enum.map(& &1["n_plus_one"])

    assert flags == [false, true, true, false]
  end

  test "full with EXPLAIN: plans for explainable queries, reasons for the others" do
    events = [query(1), query(2, explain: {:no, :not_select}, sql: "UPDATE users SET a = 1")]
    explain = fn %Event{seq: 1} -> {:ok, "SEARCH users"} end

    assert [ok, no] = build(events, :full, explain: explain)["queries"]

    assert ok["explain"] == %{"status" => "ok", "plan" => "SEARCH users"}

    assert no["explain"] == %{
             "status" => "not_explainable",
             "reason" => "only SELECT queries are explained"
           }
  end

  test "full with EXPLAIN: an error carries its reason, past the budget queries are skipped" do
    explain = fn
      %Event{seq: 1} -> {:error, :not_select}
      %Event{seq: 2} -> {:error, "database is locked"}
    end

    queries = build([query(1), query(2), query(3)], :full, explain: explain, max_explains: 2)

    assert Enum.map(queries["queries"], & &1["explain"]) == [
             %{"status" => "error", "reason" => "only SELECT queries are explained"},
             %{"status" => "error", "reason" => "database is locked"},
             %{"status" => "skipped"}
           ]
  end

  test "the short format never runs EXPLAIN" do
    explain = fn _event -> flunk("EXPLAIN ran for a short export") end
    assert %{"queries" => [_row]} = build([query(1)], :short, explain: explain)
  end
end
