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

# Message trace needs OTP 27 trace sessions (ADR 11): skipped on older OTPs.
exclude = if Code.ensure_loaded?(:trace), do: [], else: [:trace_sessions]

ExUnit.start(exclude: exclude)
