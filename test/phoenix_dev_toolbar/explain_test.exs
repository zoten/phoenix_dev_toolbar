defmodule PhoenixDevToolbar.ExplainTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.Explain
  alias PhoenixDevToolbar.Truncate

  doctest Explain

  defp capture(sql, params), do: Explain.capture(sql, Truncate.sql(sql), params)

  test "a SELECT or WITH query keeps its params, whatever the case and leading comments" do
    for sql <- [
          "SELECT 1",
          "select * from users where id = $1",
          "\n  -- list\n/* users */WITH x AS (SELECT 1) SELECT * FROM x",
          "SELECT(1)"
        ] do
      assert {:ok, [1]} = capture(sql, [1])
    end
  end

  test "writes, other statements and unknown SQL are not explained" do
    for sql <- [
          "INSERT INTO users (name) VALUES ($1)",
          "UPDATE users SET a = 1",
          "selector",
          "",
          "-- only"
        ] do
      assert {:no, :not_select} = capture(sql, [])
    end

    assert {:no, :not_select} = Explain.capture(nil, nil, [])
  end

  test "SQL too long to be stored whole is not explained" do
    sql = "SELECT " <> String.duplicate("a", 9000)
    assert {:no, :sql_truncated} = capture(sql, [])
  end

  test "params: up to 50 scalars, 4 KB of binaries in all, arrays counted element by element" do
    scalars = [1, 2.5, true, nil, "ada", <<0::128>>, ~D[2026-01-01], ~U[2026-01-01 00:00:00Z]]
    assert {:ok, ^scalars} = capture("SELECT 1", scalars)
    assert {:ok, _params} = capture("SELECT 1", [Enum.to_list(1..49), 1])

    assert {:no, :params} = capture("SELECT 1", Enum.to_list(1..51))
    assert {:no, :params} = capture("SELECT 1", [Enum.to_list(1..50), 1])
    assert {:no, :params} = capture("SELECT 1", [String.duplicate("a", 4097)])

    assert {:no, :params} =
             capture("SELECT 1", [String.duplicate("a", 3000), String.duplicate("b", 1200)])

    assert {:no, :params} = capture("SELECT 1", [%{"json" => 1}])
    assert {:no, :params} = capture("SELECT 1", [{:tuple}])
    assert {:no, :params} = capture("SELECT 1", :not_a_list)
  end
end
