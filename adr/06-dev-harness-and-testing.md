# ADR 06: Dev Harness and Testing Strategy

**Status:** Accepted  
**Area:** testing  
**Related:** [ADR 01](./01-zero-prod-footprint-and-installation.md) (prod guarantees), [ADR 04](./04-ui-delivery.md) (UI)

## Context

A library has no app to click through, but most of our value is visible only in
a running Phoenix page. We also run inside other people's processes, so
correctness and boundedness need tests, not just eyeballing.

## Decision

- **Harness**: a single-file `dev.exs` (the `Phoenix.LiveDashboard` pattern) defines an
  endpoint, router, a few LiveViews and LiveComponents that exercise every panel (N+1
  page, slow handler, chatty assigns, `Task.async` queries) and an `ecto_sqlite3` repo,
  so no database server is required. `mix dev` runs it on `PORT` (default 4000).
  `ecto_sqlite3` and `phoenix_live_reload` are `only: :dev`.
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
