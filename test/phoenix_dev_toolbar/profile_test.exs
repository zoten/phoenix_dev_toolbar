defmodule PhoenixDevToolbar.ProfileTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Profile

  doctest Profile

  defp callback(callback, us, extra \\ %{}) do
    data = Map.merge(%{callback: callback, component: nil, event: nil}, extra)
    %{Event.new(:live_view, :callback, data, at: 0) | duration: us}
  end

  defp render(us, data) do
    data = Map.merge(%{component: nil}, data)
    %{Event.new(:live_view, :render, data, at: 0) | duration: us}
  end

  test "aggregates count, total and max per callback, slowest total first" do
    profile =
      Profile.new([
        callback(:handle_event, 300, %{event: "save"}),
        callback(:handle_event, 100, %{event: "save"}),
        callback(:handle_event, 50, %{event: "inc", component: DemoWeb.CounterComponent}),
        callback(:mount, 1000)
      ])

    assert Profile.rows(profile) == [
             %{key: {:mount, nil, nil}, count: 1, total_us: 1000, max_us: 1000},
             %{key: {:handle_event, nil, "save"}, count: 2, total_us: 400, max_us: 300},
             %{
               key: {:handle_event, DemoWeb.CounterComponent, "inc"},
               count: 1,
               total_us: 50,
               max_us: 50
             }
           ]
  end

  test "LiveView renders get their own row" do
    profile = Profile.new([render(400, %{}), render(200, %{})])

    assert [%{key: {:render, nil, nil}, count: 2, total_us: 600, max_us: 400}] =
             Profile.rows(profile)
  end

  test "a component rendered on its own counts as that component's render" do
    profile = Profile.new([render(70, %{component: DemoWeb.CounterComponent})])

    assert [%{key: {:render, DemoWeb.CounterComponent, nil}, count: 1}] = Profile.rows(profile)
  end

  test "other events are ignored" do
    query = %{Event.new(:ecto, :query, %{}, at: 0) | duration: 10}

    assert Profile.rows(Profile.new([query])) == []
  end

  test "is bounded: past 100 keys, new keys go to one :other row" do
    events = for n <- 1..150, do: callback(:handle_event, 1, %{event: "event-#{n}"})

    rows = events |> Profile.new() |> Profile.rows()

    assert length(rows) == 101
    assert %{count: 50} = Enum.find(rows, &(&1.key == :other))
  end
end
