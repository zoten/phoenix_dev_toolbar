# ADR 06: Dev Harness and Testing Strategy

**Status:** Accepted  
**Area:** testing  
**Related:** [ADR 01](./01-zero-prod-footprint-and-installation.md) (prod guarantees), [ADR 04](./04-ui-delivery.md) (UI)

## Context

A library has no app to click through, but most of our value is visible only in
a running Phoenix page. We also run inside other people's processes, so
correctness and boundedness need tests, not just eyeballing.

## Decision

- **Harness**: a single-file `dev.exs` (the `Phoenix.LiveDashboard` pattern) defines a
  Bandit endpoint with `PhoenixDevToolbar.Plug`, a router with `dev_toolbar "/__pdt"`, and
  an `ecto_sqlite3` repo (`tmp/dev.sqlite3`, recreated and seeded on every boot, with
  `stacktrace: true`), so no database server is required. `mix dev` runs it on `PORT`
  (default 4000). Every page exercises a panel: Users (dead render and connected mount
  queries), Posts (an N+1 with a live patch to a preloaded version), Events (queries in
  `handle_event/3`, a slow handler, a failing query), Task.async (`Task.async_stream`
  queries attributed through `$callers`), and a dead Plug page. Phoenix and LiveView JS
  come from `deps/` through `Plug.Static`, so the harness has no build step.
  `ecto_sqlite3`, `bandit` and `jason` are `only: :dev` (`jason` also `:test`). Because
  `Demo.Repo` only exists once the script runs, `dev.exs` attaches the collector again
  after defining it; host apps do not need this, their repo modules are loadable when the
  toolbar starts. New panels add a harness page that demonstrates them.
- **Test pyramid**:
  - Unit: `Truncate`, `Store` (caps, TTL, flood guard, DOWN cleanup), attribution.
  - Telemetry: emit synthetic events with `:telemetry.execute/3` in tracked and untracked
    processes; assert recorded events through the Store API. Unique handler ids per test.
  - Plug: `Plug.Test` for injection rules (content type, status, chunked, missing `</body>`, nonce).
  - LiveView: `Phoenix.LiveViewTest` against a test endpoint in `test/support` for the
    panel and for real LiveView telemetry end to end.
  - Overhead benchmark (manual, `bench/`): handler cost for untracked processes stays
    within a few hundred nanoseconds.
- **Prod guarantee**: CI compiles a fixture host app (`test/fixtures/host_app`) with the
  guarded install in `MIX_ENV=prod` without the dependency.
- **Gate**: `mix precommit` (compile with warnings as errors, format, tests, Credo strict,
  Dialyzer, ExDoc warnings as errors). CI runs it on the minimum (Elixir 1.17 / OTP 26)
  and latest (Elixir 1.20 / OTP 29) versions.

## Consequences

- Every panel ships with a harness page that demonstrates it, which doubles as docs.

## Open limits

- No browser tests for the loader yet; candidate once the loader grows (Phase 2).
