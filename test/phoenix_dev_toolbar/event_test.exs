defmodule PhoenixDevToolbar.EventTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.Event

  doctest Event

  test "new/4 converts the native duration to microseconds" do
    duration = System.convert_time_unit(2, :millisecond, :native)

    assert %Event{plugin: :ecto, kind: :query, duration: 2000, data: %{sql: "SELECT 1"}} =
             Event.new(:ecto, :query, %{sql: "SELECT 1"}, duration: duration)
  end
end
