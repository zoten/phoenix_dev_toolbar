defmodule PhoenixDevToolbar.ExplainPostgresTest do
  # EXPLAIN on a real Postgres (ADR 08): the prefix, `SET LOCAL statement_timeout`,
  # the QUERY PLAN rows, Postgrex-encoded params and the rollback of an aborted
  # transaction. Runs when PDT_POSTGRES_URL is set (test_helper.exs), as CI does.
  use ExUnit.Case, async: true

  @moduletag :postgres

  alias DemoWeb.PostgresRepo
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Explain
  alias PhoenixDevToolbar.Truncate

  @repos [PostgresRepo]

  setup_all do
    PostgresRepo.query!("""
    CREATE TABLE users (
      id bigserial PRIMARY KEY, name text, born date, score numeric,
      active boolean, seen_at timestamptz DEFAULT now()
    )
    """)

    PostgresRepo.query!("INSERT INTO users (name) VALUES ('Ada'), ('Grace')")
    PostgresRepo.query!("CREATE SEQUENCE ticket")
    :ok
  end

  defp event(sql, params) do
    data = %{
      repo: PostgresRepo,
      sql: sql,
      result: {:ok, 1},
      explain: Explain.capture(sql, Truncate.sql(sql), params)
    }

    %Event{plugin: :ecto, kind: :query, at: 0, data: data}
  end

  defp explain(sql, params \\ []), do: Explain.run(event(sql, params), @repos)

  defp count_users, do: PostgresRepo.aggregate("users", :count)

  defp statement_timeout,
    do: PostgresRepo.query!("SHOW statement_timeout").rows

  test "a Postgres repo is offered EXPLAIN" do
    assert Explain.supported?(PostgresRepo)
    assert Explain.explainable?(event("SELECT 1", []))
  end

  test "explains a SELECT with typed params, as Postgres' plan lines" do
    sql = """
    SELECT * FROM users
    WHERE id = $1 AND name = $2 AND born < $3 AND score > $4 AND active = $5
      AND id = ANY($6) AND seen_at > now() - $7::interval
    """

    params = [
      1,
      "Ada",
      ~D[2000-01-01],
      Decimal.new("1.5"),
      true,
      [1, 2],
      %Postgrex.Interval{days: 1}
    ]

    assert {:ok, plan} = explain(sql, params)
    assert plan =~ "on users"
    assert length(String.split(plan, "\n")) > 1
    refute plan =~ "+--"
  end

  test "the query is planned, never run" do
    assert {:ok, _plan} = explain("SELECT nextval('ticket')")
    assert [[1, false]] = PostgresRepo.query!("SELECT last_value, is_called FROM ticket").rows

    assert {:ok, plan} = explain("WITH d AS (DELETE FROM users RETURNING id) SELECT * FROM d")
    assert plan =~ "Delete on users"
    assert count_users() == 2
  end

  test "the statement timeout is local to the EXPLAIN transaction" do
    before = statement_timeout()
    assert {:ok, _plan} = explain("SELECT 1")
    assert statement_timeout() == before
  end

  test "database errors are returned and leave the connection usable" do
    before = statement_timeout()

    assert {:error, message} = explain("SELECT * FROM no_such_table")
    assert message =~ "does not exist"

    assert {:error, message} = explain("SELECT * FROM users WHERE id = $1", ["not an id"])
    assert message =~ "expected an integer"

    assert count_users() == 2
    assert statement_timeout() == before
  end
end
