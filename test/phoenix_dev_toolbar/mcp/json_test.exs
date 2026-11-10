defmodule PhoenixDevToolbar.Mcp.JsonTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.Mcp.Json

  test "keeps scalars, stringifies atoms and keys" do
    assert Json.safe(%{"b" => [nil, true, false, :ok, 1.5], a: 1}) ==
             %{"a" => 1, "b" => [nil, true, false, "ok", 1.5]}
  end

  test "module atoms are inspected" do
    assert Json.safe(DemoWeb.PageLive) == "DemoWeb.PageLive"
    assert Json.safe(%{DemoWeb.PageLive => :x}) == %{"DemoWeb.PageLive" => "x"}
  end

  test "dates become ISO 8601" do
    dt = ~U[2026-11-11 10:00:00Z]
    assert Json.safe(dt) == "2026-11-11T10:00:00Z"
    assert Json.safe(~N[2026-11-11 10:00:00]) == "2026-11-11T10:00:00"
  end

  test "other structs, pids, refs, funs and tuples are inspected" do
    assert Json.safe(%URI{host: "x"}) =~ "%URI{"
    assert Json.safe(self()) =~ "#PID<"
    assert Json.safe(make_ref()) =~ "#Reference<"
    assert Json.safe(fn -> :ok end) =~ "#Function<"
    assert Json.safe({:ok, 1}) == "{:ok, 1}"
    assert Json.safe(%{{1, 2} => 3}) == %{"{1, 2}" => 3}
  end

  test "invalid UTF-8 binaries are inspected, valid ones kept" do
    assert Json.safe(<<255, 254>>) == "<<255, 254>>"
    assert Json.safe("héllo") == "héllo"
  end

  test "improper lists and deep nesting do not raise" do
    assert Json.safe([1 | 2]) == "[1 | 2]"
    deep = Enum.reduce(1..30, "x", fn _, acc -> [acc] end)
    assert Json.encode!(Json.safe(deep)) =~ "..."
  end

  test "encode! and decode round trip; decode reports a parse error" do
    data = Json.safe(%{a: [1, %{b: DemoWeb.PageLive}]})

    assert {:ok, %{"a" => [1, %{"b" => "DemoWeb.PageLive"}]}} =
             data |> Json.encode!() |> Json.decode()

    assert Json.decode("{nope") == {:error, :parse}
  end
end
