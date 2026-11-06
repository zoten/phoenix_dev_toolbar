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

  test "a new span drops the previous span's counts" do
    events = [query("SELECT u", span: 1), query("SELECT u", span: 2), query("SELECT u", span: 2)]
    {_results, state} = fold(NPlusOne.new(3), events)

    assert %{"a" => {2, counts}} = state.spans
    assert counts == %{{"SELECT u", "lib/app.ex:1: App.f/0"} => 2}
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
    {_results, state} = fold(NPlusOne.new(2), for(n <- 1..600, do: query("SELECT #{n}")))
    assert %{"a" => {1, counts}} = state.spans
    assert map_size(counts) == 500

    events = for span <- 1..60, _n <- 1..2, do: query("SELECT u", span: span)
    {_results, state} = fold(NPlusOne.new(2), events)

    assert NPlusOne.detected(state) == 60
    assert length(NPlusOne.groups(state)) == 50
    assert [%{span: 60} | _older] = NPlusOne.groups(state)
  end
end
