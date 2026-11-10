# Pre-release audit: findings and remediation plan for 0.0.1

## Context

Before a first public Hex release (0.0.x), three read-only audits ran over ADRs, code and tests:
safety and production leakage (Elixir and JS), test suite quality, product fitness with Hex
readiness and AI friendliness. I re-read the code behind the top findings (`application.ex`,
`collector.ex`, `tracker.ex`, `panel_socket.ex`, `panels/eval.ex`, `plugins/ecto.ex`, README).

Verdict: the engineering is careful (no critical finding, no confirmed third-party exploit, bounds
and never-raise rules hold, security tests on the panel socket are strong). It is not ready to
publish as is: one production-leak path under misconfiguration, an origin check that depends on
host config, a few untested core promises, and a README and docs that undersell and partly
contradict the product.

Decisions taken with the owner:
- Process actions (kill, suspend, peek, state read, trace) become **opt-in**; Eval and Cluster stay
  opt-in plugins, marked experimental
- AI features: **roadmap only** for 0.0.1
- Disclaimer: the plan produces a **human review checklist**; the owner reviews, then the README
  note is reworded

## Findings, ranked

Legend: V = verified by me in code, A = reported by an audit with file:line evidence, S = suspicion.

### P0: must fix before publishing

| # | Finding | Evidence |
|---|---|---|
| 1 | **Prod leak under Mix** (V). `enabled` defaults to true whenever Mix is loaded, so `MIX_ENV=prod mix phx.server` (or `only: [:dev, :test]`) with a dep not limited to dev starts the Store and attaches all handlers. No plug needed: `Collector.maybe_track` calls `Tracker.live_view_mount` on every mount, so every connected LiveView gets a session and its queries (with raw params for EXPLAIN) are stored | `application.ex:42,53`, `phoenix_dev_toolbar.ex:22`, `collector.ex:204`, `tracker.ex:60-73` |
| 2 | **Panel socket origin check relies on the host's `check_origin`**, which is `false` in generated dev configs (V, `dev.exs:20`). Any web page in the dev's browser can open the socket as a loopback client; only the signed session token and same-origin policy stand between it and kill, suspend, Eval. A permissive CORS plug ahead of the toolbar could complete the chain (S). ADR 12:49 relies on `check_origin`, contradicting ADR 04:193 | `panel_socket.ex:44,59` |
| 3 | **Destructive actions on by default** for loopback, against ADR 00's "small, focused" promise (V) | `config.ex:13`, `client_policy.ex:22` |
| 4 | **Version and release metadata incoherent** (V): `@version "0.1.0"`, README installs from GitHub and says "not on Hex yet", ADR 01 says `~> 0.1`, CHANGELOG only has `[Unreleased]` with "Breaking" lines for an unreleased project, no tag for `source_ref` | `mix.exs:4,114`, `README.md:10,19`, `adr/01:42` |
| 5 | **README does not show the product** (V): one sentence of features, no screenshot, no requirements (Phoenix 1.8, LiveView 1.1, Elixir 1.17, OTP 26.2/27 for some features), no CSP or troubleshooting section, "fully AI-coded and not reviewed" disclaimer next to kill and eval features | `README.md:5-13` |
| 6 | **Hexdocs contradict the code** (A): Plug moduledoc says the panel uses the host's LiveView socket (it has its own); `:defaults` documented as 3 plugins (it is 5); moduledocs cite "ADR NN" and SECURITY.md, which are not in the package or docs extras | `plug.ex:12`, `plugin.ex:13`, `guides/writing-a-plugin.md:3`, `mix.exs:107,115` |
| 7 | **Untested core promises** (A): disabled means no children and no handlers (`application.ex:56,66` never exercised); forged `eval` event under default config (only the UI is asserted); Collector's own catch path with the Store down; HostCheck on the websocket upgrade and export; client address over the real socket (`x_headers` drop would fail open) | `application_test.exs`, `eval_test.exs:53-68`, `collector_test.exs:76`, `host_check_test.exs:61`, `panel_socket.ex:46` |

### P1: should fix before publishing

| # | Finding | Evidence |
|---|---|---|
| 8 | **Ecto collector cost depends on param size** (A, measured 140 to 220 ms for a 50x50x50 param in the host process): `Truncate.redact/1` bounds shape, not node count | `plugins/ecto.ex:138`, `truncate.ex:323-346` |
| 9 | **Loose per-event byte cap** (A): `inspect_value` caps item counts, 100 strings of 5 KB give ~52 KB; theoretical store ceiling far above what a dev expects | `truncate.ex:10`, `store.ex:46-54` |
| 10 | **Config surprises** (A): `redact:` replaces the defaults (setting `["api_key"]` stops redacting `password`); Ecto tab silently empty without `repos:`; `ttl_ms`, `sweep_ms`, `down_grace_ms`, plug `:path` and `:nonce_assign` documented only in ADRs or moduledoc | `truncate.ex:179`, `plugins/ecto.ex:30-33`, `store.ex:50-53` |
| 11 | **Built-in plugins users configure by name are `@moduledoc false`**; README claims the listed options are complete, Ecto also takes `repos:` (A) | `plugins/*.ex`, `README.md:76` |
| 12 | **Flaky test risks** (A): real 30 s Store sweep runs during the suite while tests create epoch-dated rows; 1 s wall-clock action limits; `eventually/2` polling a real 1 s timer; count-bounded busy waits | `store.ex:51,352`, `system_panel_test.exs:427`, `process_panel_test.exs:94,161`, `eval_test.exs:150` |
| 13 | **Tracer and Suspender gaps** (A): Tracer TTL stop and Tracer crash untested; "panel dies, suspended process resumes" only unit tested | `tracer.ex:126`, `suspender_test.exs:48` |
| 14 | **CI gaps** (A): no `mix hex.build --unpack` file check; fixture never boots the toolbar without Ecto (compile only, dep warnings not fatal); `mix precommit` lacks the stale-bundle and fixture steps CI runs | `.github/workflows/ci.yml`, `mix.exs:90-99` |
| 15 | **Small hardening** (A): `before_send` rescues only exceptions; injection keeps a preset `content-length` (S); loader's shadow `<style>` has no nonce under strict `style-src`; Eval ignores `actions: false` | `plug.ex:282-290,309`, `loader.js:169`, `panels/eval.ex:98` |
| 16 | **Plugin API stability** (A): `@page` struct undocumented, `pdt-` CSS classes are de facto API, `Truncate.changes/2` and `snapshot/1` public but internal | `panel.ex:45`, `guides/writing-a-plugin.md:210` |
| 17 | **ADR drift** (A): RTT sparkline promised, never built (ADR 00:29, 04:57); stale tab lists (04:177, 05:17); `panel.js` "about 1 KB" is 8.7 KB (04:96); message trace described as future (02:165); unwritten benchmark cited (06:51); AGENTS.md "single `Process.get/1`" is really two plus an ETS lookup per caller | listed files |

### P2: after 0.0.1 (roadmap)

- Duplicated test helpers (`flush/1`, open panel, `ms/1`, env save/restore in 4+ files) and 154 text-filter `has_element?` assertions
- No DOM-level JS tests: `loader.js` and `panel.js` wiring, including the postMessage origin gate
- EXPLAIN tested only on SQLite (no Postgres in CI)
- No overhead benchmark for the hot path claim
- CHANGELOG audience (personal reminder, yet shipped), no CONTRIBUTING.md, AGENTS.md half generic
- Panel allowlist churn by a hostile page (nuisance), `PDT_LIVE_VIEW` read in the shipped `mix.exs`
- Positioning: overlaps LiveDebugger (LiveView tab) and LiveDashboard (System tab); the unique value is per-page attribution of queries to callbacks and tasks, N+1 per span, one-click EXPLAIN
- **AI friendliness** (roadmap only, per decision): nothing is reachable without a browser except the Ecto JSON export; no `usage-rules.md`. Roadmap order: (S) documented `PhoenixDevToolbar.Report` over `Store.sessions/0`, `events/2`, `NPlusOne`, `EctoExport.build/3`; (S) shipped `usage-rules.md`; (S) document the standalone panel URL plus `data-pdt-*` row attributes; (M) page-level Markdown "Copy for LLM"; (L) loopback MCP endpoint

## Remediation plan

Step 0: copy this plan to `docs/2026-11-10-pre-release-audit-plan.md` (project convention). Tests are
written first in each batch. Batches A and B are risky (host processes, access control): one combined
reviewer each. C to F are covered by the final review. Each batch is one subagent task under ~40 turns.

### Execution mode (owner's instruction)

Auto mode, subagent driven. Implementers run on **Sonnet**, one agent per batch, each given this
plan's batch section with exact files and line ranges. Reviewers run on **Opus**: one combined
reviewer after Batch A and one after Batch B only. Findings are triaged (must-fix, batch, defer)
before any fix agent. Batches run in order A, B, C, D, E, F on the same branch (they share files:
`plug.ex`, `truncate.ex`, README, ADRs), each committed as its own slice with staged files only.
After Batch F the orchestrator runs `mix precommit` once, then the `feature-review` skill over the
whole commit range as the **final feature review**, and fixes its must-fix findings in one batch.
Work happens on a branch off `main`; nothing is pushed, tagged or published.

### Batch A: enablement and access (P0 1, 2, 3; P1 15 Eval part)

- `lib/phoenix_dev_toolbar/application.ex`: `settle_enabled/2` takes the Mix env; when `enabled` is
  unset, enable only for `Mix.env() == :dev` (and `:test` of this library via explicit config in
  `config/config.exs`), otherwise disable with the existing warning, reworded. Expose
  `@doc false child_specs/1` so the disabled path is testable
- `lib/phoenix_dev_toolbar/panel_socket.ex`: before `Transport.check_origin/4`, require the `Origin`
  header to match the request's own scheme, host and port; refuse a missing origin. Keep the host
  option pass-through for `timeout` and `max_frame_size` only
- `lib/phoenix_dev_toolbar/plug.ex`: strip `access-control-*` response headers on `/panel` and `/export`
- `lib/phoenix_dev_toolbar/client_policy.ex` and `config.ex`: default `actions: false`; `:loopback`
  and `:any` unchanged. Panels render the existing "actions off" state with a hint naming the option
- `lib/phoenix_dev_toolbar/panels/eval.ex`: `allowed/1` also refuses when `ClientPolicy.mode() == false`
- Tests: `application_test.exs` (disabled gives `[]` children, no `{Collector, _}` handlers, prod env
  under Mix disables), `panel_socket_test.exs` (foreign and missing Origin get 403 with host
  `check_origin: false`; wrong Host on the upgrade gets 403; join with `X-Forwarded-For` is not a
  loopback client), `host_check_test.exs` (export path, `log_refused/1` cap), `eval_test.exs` (forged
  `eval` under default config does not run, note element has a DOM id), `plug_test.exs` (toolbar
  paths pass through when disabled)
- ADRs edited in place: 01 (enablement rule), 04 (origin rule), 10 (actions opt-in), 12 (drop the
  `check_origin` reasoning); `SECURITY.md`; README config block

### Batch B: hot path bounds (P1 8, 9, 15 plug part; P0 7 collector part)

- `lib/phoenix_dev_toolbar/plugins/ecto.ex:138`: params go through the budgeted
  `Truncate.preview/3` (existing, 200 nodes, `truncate.ex:231`) and a byte cap via `Truncate.string/2`
- `lib/phoenix_dev_toolbar/truncate.ex`: give `redact/2` a node budget; fix its doc
- `lib/phoenix_dev_toolbar/plug.ex`: `before_send` uses `catch kind, reason`; delete `content-length`
  next to the `etag` removal
- Tests: `truncate_test.exs` (wide and deep param stays under a node and byte budget),
  `plugins/ecto_test.exs` (stored params size bound), `collector_test.exs` (Store down and malformed
  mount metadata: no raise, handler still attached, one log line; untracked emit never reaches a
  plugin), `plug_test.exs` (`before_send` throw leaves the response untouched)
- ADR 02 and 03 edited in place; AGENTS.md hot path wording matches the code

### Batch C: config and public docs (P0 6; P1 10, 11, 16)

- `truncate.ex:179`: `redact:` merges with the defaults; `plugins/ecto.ex`: with no `repos:`, fall
  back to the host apps' `:ecto_repos`, else log one warning
- Public moduledocs with option tables for `Plugins.Ecto`, `Process`, `System`, `LiveView`,
  `Request`; ExDoc groups "Setup" and "Built-in plugins" in `mix.exs`
- Fix `plug.ex:12` and the `:defaults` lists; replace bare "ADR NN" in public docs with absolute
  GitHub links; add `SECURITY.md` to docs extras
- "Experimental" admonition on `Plugin`, `Panel`, `Plugins.Eval`, `Plugins.Cluster`; document the
  `@page` fields and the stable `pdt-` classes; `Truncate.changes/2` and `snapshot/1` get `@doc false`
- Tests: `config_test.exs`, `truncate_test.exs` (redact merge), `plugins/ecto_test.exs` (repos fallback)

### Batch D: test determinism and remaining gaps (P1 12, 13)

- `config/config.exs` test block: `limits: [sweep_ms: :timer.hours(24)]`
- `test/support`: `wait_until/2`, `PageHelpers.open_panel/2`, `flush/1`, `put_app_env/2`; replace
  the count-bounded loops and `eventually/2` (use `Panel.send_now`, as `panel_live_view_tab_test` does)
- Action rate limit and GC limit: make the last-action time settable from tests instead of two
  clicks within a wall-clock second
- `tracer_test.exs`: TTL stop and Tracer crash; `system_panel_test.exs`: kill the panel after
  Suspend, target answers a ping; run all 7 `EvalRunner.queries/0`

### Batch E: release mechanics, README, CI (P0 4, 5; P1 14, 17)

- `mix.exs`: `@version "0.0.1"`, links for Changelog and Docs; README dep
  `{:phoenix_dev_toolbar, "~> 0.0.1", only: :dev}`; ADR 01 same
- README: "What you get" (one line per tab), Requirements, "Troubleshooting and CSP" (nonce, 403
  host guard, Docker and `actions`, compressed responses), "How this differs" (LiveDebugger,
  LiveDashboard, phoenix_profiler), screenshot placeholder for the owner to record from `mix dev`
- `CHANGELOG.md`: `## [0.0.1]` with a short user-readable summary, pre-release "Breaking" lines dropped
- CI: `mix hex.build --unpack` plus file assertions; fixture step that boots without Ecto and calls
  the plug once; add stale-bundle check to `mix precommit`
- ADR drift from finding 17 fixed in place; roadmap gets the P2 list and the AI feature order
- Check hex.pm that the name is free (WebSearch or `mix hex.info phoenix_dev_toolbar`)

### Batch F: human review checklist (owner action)

Write `docs/2026-11-10-human-review-checklist.md`: for each of `Collector`, `Tracker`, `Store`,
`Plug`, `PanelSocket`, `HostCheck`, `ClientPolicy`, `EvalRunner`, `Explain`, `ProcessActions`,
`Suspender`, `Tracer`, `loader.js`: the invariant it must hold, the lines that hold it and the test
that proves it. After the owner's review, the README disclaimer becomes "AI-assisted; the modules
that run in your processes or gate access were reviewed by a human (see checklist)".

## Risks

- **Hot path cost**: Batch B changes run in host processes; the node budget must be cheaper than
  today's walk, never dearer (assert with a bounded-reduction or size test, not timing)
- **Production footprint**: `Mix.env/0` is only called when Mix is loaded; releases keep the current path
- **Memory bounds**: byte cap on params must apply before `Store.insert`
- **Host conflicts**: the strict Origin rule must still pass for the same-origin iframe behind a dev
  proxy or tunnel (`allowed_hosts`): compare against the request's own host, and verify by hand
- **Public API and docs**: `actions` default and `redact` merge are behaviour changes: CHANGELOG lines
- **Tests and ADR sync**: every batch edits its ADRs in place; no failing test is assumed pre-existing

## Verification

- Per batch: affected test files plus `mix compile --warnings-as-errors`
- Once on the merged result: `mix precommit`, confirming exit code 0 and all four checkpoints (tests
  0 failures, Credo no issues, Dialyzer 0 errors, ExDoc no warnings)
- `PORT=4001 mix dev` in a real browser: toolbar loads, panel socket joins, actions are off by
  default and work with `actions: :loopback`, Ecto tab shows queries with large params truncated
- From the browser console on another origin: `new WebSocket("ws://localhost:4001/__pdt/live/websocket?vsn=2.0.0")` is refused
- `cd fixtures/host_app && MIX_ENV=prod mix phx.server` style check: no `pdt_` ETS tables, no Collector handlers
- `mix hex.build --unpack`: `priv/static/{loader.js,panel.js,panel.css}` present; no `examples/`, `test/`, `dev.exs`
- `mix hex.publish --dry-run` is left to the owner, with the tag `v0.0.1`
