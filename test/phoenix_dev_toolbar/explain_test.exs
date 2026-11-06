defmodule PhoenixDevToolbar.ExplainTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.Event
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

  test "params: up to 50 scalars, 4 KB of binaries in all, arrays counted with their elements" do
    scalars = [1, 2.5, true, nil, "ada", <<0::128>>, ~D[2026-01-01], ~U[2026-01-01 00:00:00Z]]
    assert {:ok, ^scalars} = capture("SELECT 1", scalars)
    assert {:ok, _params} = capture("SELECT 1", [Enum.to_list(1..48), 1])
    assert {:no, :params} = capture("SELECT 1", [Enum.to_list(1..49), 1])

    assert {:no, :params} = capture("SELECT 1", Enum.to_list(1..51))
    assert {:no, :params} = capture("SELECT 1", [String.duplicate("a", 4097)])

    assert {:no, :params} =
             capture("SELECT 1", [String.duplicate("a", 3000), String.duplicate("b", 1200)])

    assert {:no, :params} = capture("SELECT 1", [%{"json" => 1}])
    assert {:no, :params} = capture("SELECT 1", [{:tuple}])
    assert {:no, :params} = capture("SELECT 1", :not_a_list)
  end

  test "arrays are one level of scalars, and count against the budget themselves" do
    assert {:ok, _params} = capture("SELECT 1", [[1, 2], [3]])
    assert {:no, :params} = capture("SELECT 1", List.duplicate([], 51))
    assert {:no, :params} = capture("SELECT 1", [[[1]]])
  end

  test "binaries are copied: a param cut out of a large body does not keep it alive" do
    body = String.duplicate("x", 100_000)
    param = binary_part(body, 10, 100)
    assert :binary.referenced_byte_size(param) == 100_000

    assert {:ok, [copied, [array_item]]} = capture("SELECT 1", [param, [param]])
    assert :binary.referenced_byte_size(copied) == 100
    assert :binary.referenced_byte_size(array_item) == 100
  end

  test "invalid UTF-8 or a multibyte keyword never raise" do
    assert {:no, :not_select} = capture(<<0xFF, 0xFE, "SELECT">>, [])
    assert {:no, :not_select} = capture("sélectionner", [])
  end

  describe "run/2" do
    @repos [DemoWeb.SQLiteRepo]

    defp event(sql, params, overrides \\ %{}) do
      data =
        Map.merge(
          %{
            repo: DemoWeb.SQLiteRepo,
            sql: sql,
            explain: Explain.capture(sql, Truncate.sql(sql), params)
          },
          overrides
        )

      %Event{plugin: :ecto, kind: :query, at: 0, data: data}
    end

    test "explains a captured SELECT with its params on the real database" do
      assert {:ok, plan} = Explain.run(event("SELECT * FROM users WHERE id = ?", [1]), @repos)
      assert plan =~ "SEARCH users USING INTEGER PRIMARY KEY"
    end

    test "a database error is returned, not raised" do
      assert {:error, message} = Explain.run(event("SELECT * FROM no_such_table", []), @repos)
      assert message =~ "no such table"
    end

    test "refuses what it must not run" do
      assert {:error, :repo_not_configured} = Explain.run(event("SELECT 1", []), [])
      assert {:error, :not_explainable} = Explain.run(event("SELECT 1", [%{"json" => 1}]), @repos)

      update = event("SELECT 1", [], %{sql: "UPDATE users SET name = 'x'"})
      assert {:error, :not_select} = Explain.run(update, @repos)

      two = event("SELECT 1; DELETE FROM users", [])
      assert {:error, :multiple_statements} = Explain.run(two, @repos)

      assert {:error, :unsupported_adapter} =
               Explain.run(event("SELECT 1", [], %{repo: DemoWeb.FakeRepo}), [DemoWeb.FakeRepo])

      assert {:error, :not_query} =
               Explain.run(%Event{plugin: :request, kind: :query, at: 0}, @repos)

      assert DemoWeb.SQLiteRepo.aggregate("users", :count) == 2
    end

    test "semicolons in strings, identifiers or comments, or a trailing one, are fine" do
      for sql <- [
            "SELECT * FROM users WHERE name = 'a;b'",
            ~s|SELECT "id;" FROM (SELECT 1 AS "id;")|,
            "SELECT 1 -- ; not a separator",
            "SELECT 1 /* ; */",
            "SELECT 1;  "
          ] do
        assert {:ok, _plan} = Explain.run(event(sql, []), @repos), sql
      end
    end
  end
end
