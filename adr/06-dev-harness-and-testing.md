# ADR 06: Dev Harness and Testing Strategy

**Status:** Implemented (2026-11-05)  
**Area:** testing  
**Related:** [ADR 01](./01-zero-prod-footprint-and-installation.md) (prod guarantees), [ADR 04](./04-ui-delivery.md) (UI)

## Context

A library has no app to click through, but most of our value is visible only in
a running Phoenix page. We also run inside other people's processes, so
correctness and boundedness need tests, not just eyeballing.

## Decision

- **Harness**: a single-file `dev.exs` (the `Phoenix.LiveDashboard` pattern) defines a
  Bandit endpoint with `PhoenixDevToolbar.Plug` (before the session plug, as in a
  generated endpoint), a router without any toolbar routes, and an `ecto_sqlite3` repo
  (`tmp/dev.sqlite3`, recreated and seeded on every boot, with `stacktrace: true`), so no
  database server is required. `mix dev` runs it on `PORT`
  (default 4000). Every page exercises a panel: Users (dead render and connected mount
  queries), Posts (an N+1 with a live patch to a preloaded version), Events (queries in
  `handle_event/3`, a slow handler, a failing query), Task.async (`Task.async_stream`
  queries attributed through `$callers`), Components (LiveComponents with events and
  `send_update`, a nested LiveView, a `push_event`), Assigns (large, nested and
  sensitive assigns, a per keystroke diff, a slow `handle_params`), Oban jobs (the example
  plugin, `examples/oban`: Oban on the SQLite repo with the Lite engine, inserts, an
  `insert_all`, a unique conflict, an invalid insert), Plugin errors (a demo plugin that
  fails on demand in its collector, summary, tab callbacks or template, to check
  quarantine and Re-enable), Memory (grows assigns, makes garbage, floods the message
  queue and starts a task, for the Process tab), and a dead Plug page. Phoenix and LiveView JS
  come from `deps/` through `Plug.Static`, so the harness has no build step.
  `ecto_sqlite3`, `bandit` and `jason` are `only: :dev` (`jason` also `:test`), `oban`
  `only: [:dev, :test]`: the example plugins in `examples/` are compiled in tests
  (`elixirc_paths`) and loaded by `dev.exs`, never shipped (the package lists `lib/`). Because
  `Demo.Repo` only exists once the script runs, `dev.exs` attaches the collector again
  after defining it; host apps do not need this, their repo modules are loadable when the
  toolbar starts. New panels add a harness page that demonstrates them.
- **Test pyramid**:
  - Unit: `Truncate`, `Store` (caps, TTL, flood guard, DOWN cleanup); attribution is covered through the collector and
    plug tests.
  - Telemetry: emit synthetic events with `:telemetry.execute/3` in tracked and untracked
    processes; assert recorded events through the Store API. Unique handler ids per test.
  - Plug: `Plug.Test` for injection rules (content type, status, chunked, missing `</body>`, nonce).
  - LiveView: `Phoenix.LiveViewTest` against a test endpoint in `test/support` for the
    panel and for real LiveView telemetry end to end (host LiveViews with a component,
    driven through `DemoWeb.Endpoint`). Plugin API: test plugins in `test/support`
    (a tab and badge, one that fails on demand everywhere its code runs) and the Oban
    example drive the public API through a real host LiveView.
  - Determinism: no test waits on the wall clock. The test config sets the Store's sweep
    interval to 24 h (tests call `Store.sweep/1`), the one-a-second limits of GC now and of
    process actions read `ProcessInspector.now_ms/0`, which tests override with the
    `:clock_ms` app env (a zero-arity function), and panel timers are delivered with
    `Panel.send_now/4` (`PageHelpers.tick_now/4`). Waits poll under a deadline
    (`ProcessHelpers.wait_until/2`), never a fixed count of iterations. Shared helpers live in
    `test/support` (`PageHelpers.open_panel/2` and `flush/1`, `ProcessHelpers.ponger/0`,
    `EnvHelpers.put_app_env/2` restoring the env on exit).
  - JS: the loader's pure helpers (`assets/js/client_events.mjs`) have unit tests run by
    `node --test` (`mix test.js`, Node built-ins only, part of `mix precommit`, so
    contributors need Node 22+; CI runs it in the latest row). The wiring (listeners, `postMessage`, hooks) is checked by hand.
  - Overhead benchmark (manual, `bench/`): handler cost for untracked processes, not
    written yet (open limit below).
- **Prod guarantee**: `fixtures/host_app` installs the package exactly as the README says
  (path dependency, `only: :dev`), with a third party plugin in `dev/` compiled in `:dev`
  only, as the plugin guide says. CI compiles it with `--warnings-as-errors` in
  `MIX_ENV=prod`, where the dependency does not exist, and in `MIX_ENV=dev`. It lives
  outside `test/` so the formatter and Credo never scan its `deps/`. It caught that a
  router macro cannot be installed this way (ADR 01).
- **Gate**: `mix precommit` (compile with warnings as errors, format, tests, Credo strict,
  Dialyzer, ExDoc warnings as errors) locally. Credo runs its defaults plus the opt-in
  checks listed in `.credo.exs` (`extra:`; `enabled:` would run only those), Dialyzer
  adds `:unmatched_returns`, `:error_handling`, `:extra_return` and `:missing_return`.
  `.dialyzer_ignore.exs` lists only the test fixtures that raise on purpose, by file and
  warning type, and an unused entry fails the run. CI runs two rows: the minimum supported
  stack (Elixir 1.17 / OTP 26 / LiveView `~> 1.1.0`, through the `PDT_LIVE_VIEW`
  override read by `mix.exs`) runs compile and tests with warnings as errors; the latest
  (Elixir 1.20 / OTP 29 / the locked LiveView) also runs format, unused deps, Credo,
  Dialyzer, ExDoc, the fixture host app and the built assets check. The minimum row is
  what covers `PhoenixDevToolbar.LiveViewCompat` on LiveView 1.1. `agent-tools/ci-min.sh`
  replays that row locally in Docker, on a copy of the working tree: `mix precommit`
  only runs on the local toolchain.

## Consequences

- Every panel ships with a harness page that demonstrates it, which doubles as docs.

## Open limits

- No browser tests: the loader and panel wiring are checked by hand in `mix dev`. A JS
  client behaviour (a hook push locking its element dropped stream resets) was only
  visible in a real browser.
- The overhead benchmark (`bench/`) is not written yet.
