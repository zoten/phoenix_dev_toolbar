# EXPLAIN on Postgres in CI: plan

Roadmap item "EXPLAIN tests on Postgres in CI" (After 0.0.1), ADR 08 and ADR 06.
Today `Explain.run/2` is only exercised on SQLite. The Postgres branch has its own
code: the `EXPLAIN ` prefix, `SET LOCAL statement_timeout`, the `QUERY PLAN` row
format, `$n` params encoded by Postgrex, and the rollback of an aborted transaction.

## Scope

- `postgrex` as a `only: :test` dependency (no change for host apps, the package
  lists `lib/` and `ecto_sql` stays optional).
- `DemoWeb.PostgresRepo` in `test/support`, started by `test_helper.exs` only when
  `PDT_POSTGRES_URL` is set. Otherwise tests tagged `:postgres` are excluded, so
  `mix test` and `agent-tools/ci-min.sh` need no database.
- Isolation: one schema per run (`pdt_test_<os pid>`), set as `search_path` on
  connect, dropped in `ExUnit.after_suite/1`: concurrent runs and a shared local
  database never collide.
- `test/phoenix_dev_toolbar/explain_postgres_test.exs` (`@moduletag :postgres`):
  - a captured SELECT with typed params (integer, text, date, Decimal, boolean,
    an array through `= ANY($1)`, a `Postgrex.Interval`) is explained, the plan is
    Postgres' text lines (no table border)
  - EXPLAIN never runs the query: `nextval` in the select list leaves the sequence
    untouched, a data-modifying `WITH ... DELETE ... RETURNING` leaves the rows
  - `SET LOCAL statement_timeout` does not leak to the pooled connection
  - a database error (missing relation, a param of the wrong type) is returned, not
    raised, and the connection is usable afterwards (no aborted transaction left)
  - `supported?/1` and `explainable?/1` are true for a Postgres repo
- CI: a `postgres:17` service on both matrix rows, `PDT_POSTGRES_URL` in the job env.

## Risks

- Hot path, prod footprint, memory, host conflicts: none, test-only code and deps.
- A local `mix test` silently skips Postgres: acceptable, CI always runs it; the
  ADR documents the env var. When the variable is set and the database is
  unreachable, the helper raises instead of skipping.
- `postgrex` in the test env changes Dialyzer's PLT (precommit runs in test): the
  `Postgrex.*` structs named in `Explain` now resolve, nothing else should change.
- The service image is not bumped by Dependabot: pinned to a major (`postgres:17`).

## Docs

ADR 08 (Consequences: tests on SQLite and Postgres), ADR 06 (test database note),
CHANGELOG line, roadmap tick.
