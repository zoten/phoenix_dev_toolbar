defmodule PhoenixDevToolbar.NPlusOneTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.NPlusOne

  defp query(sql, opts \\ []) do
    %Event{
      plugin: :ecto,
      kind: :query,
      at: 0,
      sid: Keyword.get(opts, :sid, "a"),
      span: Keyword.get(opts, :span, 1),
      seq: Keyword.get(opts, :seq),
      data: %{sql: sql, stacktrace: Keyword.get(opts, :stacktrace, ["lib/app.ex:1: App.f/0"])}
    }
  end

  defp fold(state, events) do
    Enum.map_reduce(events, state, fn event, state ->
      {state, result} = NPlusOne.add(state, event)
      {result, state}
    end)
  end

  test "the threshold-th repetition in one span is detected, later ones repeat it" do
    {results, state} = fold(NPlusOne.new(3), for(seq <- 1..4, do: query("SELECT u", seq: seq)))

    assert results == [:ok, :ok, :detected, :repeated]
    assert NPlusOne.detected(state) == 1

    assert [%{sql: "SELECT u", origin: "lib/app.ex:1: App.f/0", count: 4, seq: 3}] =
             NPlusOne.groups(state)
  end

  test "repetitions across spans or sessions are not an N+1" do
    events =
      for(span <- 1..5, do: query("SELECT u", span: span)) ++
        for(sid <- ~w(b c d e), do: query("SELECT u", sid: sid))

    {results, state} = fold(NPlusOne.new(3), events)

    assert Enum.uniq(results) == [:ok]
    assert NPlusOne.groups(state) == []
  end

  test "the origin tells two call sites apart; without origins the SQL alone counts" do
    two_sites = [
      query("SELECT u", stacktrace: ["lib/a.ex:1"]),
      query("SELECT u", stacktrace: ["lib/b.ex:1"]),
      query("SELECT u", stacktrace: ["lib/a.ex:1"])
    ]

    assert {[:ok, :ok, :ok], _state} = fold(NPlusOne.new(3), two_sites)

    no_origin = for _n <- 1..3, do: query("SELECT u", stacktrace: [])
    assert {[:ok, :ok, :detected], state} = fold(NPlusOne.new(3), no_origin)
    assert [%{origin: nil}] = NPlusOne.groups(state)
  end

  test "spans of one sid can interleave (nested LiveViews share a sid)" do
    events = for _n <- 1..5, q <- [query("SELECT u", span: 1), query("SELECT o", span: 2)], do: q

    {_results, state} = fold(NPlusOne.new(5), events)
    assert NPlusOne.detected(state) == 2
  end

  test "only a sid's last 4 spans are counted" do
    old = for _n <- 1..4, do: query("SELECT u", span: 1)
    others = for span <- 2..5, do: query("SELECT x", span: span)

    {_results, state} = fold(NPlusOne.new(5), old ++ others ++ [query("SELECT u", span: 1)])
    assert NPlusOne.detected(state) == 0

    {_results, state} =
      fold(NPlusOne.new(5), old ++ Enum.take(others, 3) ++ [query("SELECT u", span: 1)])

    assert NPlusOne.detected(state) == 1
  end

  test "disabled, or events that are not queries, change nothing" do
    disabled = NPlusOne.new(false)
    assert {^disabled, :ok} = NPlusOne.add(disabled, query("SELECT u"))

    state = NPlusOne.new(2)
    assert {^state, :ok} = NPlusOne.add(state, %Event{plugin: :ecto, kind: :other, at: 0})
  end

  test "rejects a threshold below 2" do
    assert_raise FunctionClauseError, fn -> NPlusOne.new(1) end
  end

  test "memory is bounded: distinct queries per span and kept groups are capped" do
    # Past 500 distinct queries in a span, new ones are not counted.
    distinct = for n <- 1..500, do: query("SELECT #{n}")

    {results, _state} =
      fold(NPlusOne.new(2), distinct ++ [query("SELECT new"), query("SELECT new")])

    assert List.last(results) == :ok

    events = for span <- 1..60, _n <- 1..2, do: query("SELECT u", span: span)
    {_results, state} = fold(NPlusOne.new(2), events)

    assert NPlusOne.detected(state) == 60
    assert length(NPlusOne.groups(state)) == 50
    assert [%{span: 60} | _older] = NPlusOne.groups(state)
  end
end
