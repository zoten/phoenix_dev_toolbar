# The host side of LiveView tests: a PubSub and an endpoint, as a Phoenix app has.
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: DemoWeb.PubSub}], strategy: :one_for_one)
{:ok, _} = DemoWeb.Endpoint.start_link()

# A real SQL database for the EXPLAIN tests (ADR 08): one file per run, so
# concurrent `mix test` runs never share it, removed when the suite ends.
database = Path.expand("../tmp/test-#{System.pid()}.sqlite3", __DIR__)
File.mkdir_p!(Path.dirname(database))

ExUnit.after_suite(fn _result ->
  for suffix <- ["", "-shm", "-wal"], do: File.rm(database <> suffix)
end)

Application.put_env(:phoenix_dev_toolbar, DemoWeb.SQLiteRepo, database: database, pool_size: 1)
{:ok, _} = DemoWeb.SQLiteRepo.start_link()
DemoWeb.SQLiteRepo.query!("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
DemoWeb.SQLiteRepo.query!("INSERT INTO users (name) VALUES ('Ada'), ('Grace')")

# Postgres for the EXPLAIN tests (ADR 08), when PDT_POSTGRES_URL is set (CI sets
# it): one schema per run, first in search_path, dropped when the suite ends.
postgres? =
  case System.get_env("PDT_POSTGRES_URL", "") do
    "" ->
      false

    url ->
      schema = "pdt_test_#{System.pid()}"

      Application.put_env(:phoenix_dev_toolbar, DemoWeb.PostgresRepo,
        url: url,
        pool_size: 1,
        after_connect: {Postgrex, :query!, ["SET search_path TO #{schema}", []]}
      )

      {:ok, _} = DemoWeb.PostgresRepo.start_link()
      DemoWeb.PostgresRepo.query!("DROP SCHEMA IF EXISTS #{schema} CASCADE")
      DemoWeb.PostgresRepo.query!("CREATE SCHEMA #{schema}")

      ExUnit.after_suite(fn _result ->
        DemoWeb.PostgresRepo.query!("DROP SCHEMA IF EXISTS #{schema} CASCADE")
      end)

      true
  end

# Message trace needs OTP 27 trace sessions (ADR 11): skipped on older OTPs.
# The built-in JSON module needs Elixir 1.18: skipped on 1.17.
exclude =
  [
    trace_sessions: not Code.ensure_loaded?(:trace),
    postgres: not postgres?,
    json_module: not Code.ensure_loaded?(JSON)
  ]
  |> Enum.filter(fn {_tag, skip?} -> skip? end)
  |> Enum.map(fn {tag, _skip?} -> tag end)

ExUnit.start(exclude: exclude)
