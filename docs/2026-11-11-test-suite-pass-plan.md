# Test suite pass

A review of the whole suite (Elixir and JS) against Kent Beck's test desiderata,
helper duplication, weak assertions and implementation coupling. The suite is
behavioural overall; this pass removes the flaky or leaking tests, the assertions
that cannot fail, the copied helpers, and adds the missing JS wiring tests. One
library change: the unused `down_grace_ms` limit is removed (0.0.x may break).

Line numbers are from commit 218a68b and drift as batches land: search, do not trust them.

## Batch A: flaky and leaking tests, `down_grace_ms`

- `tracer_test.exs`: `on_exit(fn -> Tracer.stop(self()) end)` runs in the on_exit
  process (capture the owner first); the kill test (129-151) spends the toolbar
  supervisor's restart intensity (reproduced with `--repeat-until-failure`) and waits
  on `which_children` (no ordering); the `stop(pid)` then `sync()` waits (57, 86, 100)
  do not order the Tracer's own DOWN: use `wait_until/2`; the private
  `:sys.get_state(Tracer).trace.session` reads (116, 132) go behind one helper.
- `panel_socket_test.exs` `eval_tab_diff/2` attaches Eval with `allow: :eval` and
  never restores the plugins.
- `report_test.exs` (disabled toolbar) and `plug_test.exs` (17-25, 55, 277, 288):
  raw `Application.put_env` with a forced or deleted value on exit: use `EnvHelpers`.
- `panel_payload_test.exs` `drain/1`: a 50 ms receive window; use
  `:erlang.trace_delivered/1` then drain with `after 0`.
- `system_panel_test.exs:423` `refute_receive ..., 50`: assert the suspended status.
- `truncate_test.exs` (224-227, 371-377): absolute reduction bounds depend on the
  OTP and JIT: compare with a baseline measured in the same test, or keep the node budget.
- Remove `down_grace_ms` (Store defaults and type, Config zero limits, ADR 03, README,
  `store_test.exs`): an old config now logs the unknown key and boots.

## Batch B: assertions that cannot fail

Every refute-only or vacuous test gets a positive check that the feature still works.

- `report_test.exs:770-772` (rows split on "\n" never contain "\n").
- `refute_received {:DOWN, ...}` right after a kill (the exit is asynchronous):
  `system_panel_test.exs` forged actions (490-545), `process_actions_test.exs` (27, 41,
  66). Use `ponger()` and `assert_receive {:pong, ^pid}`, plus the visible outcome.
- Malformed input tests: `explain_panel_test.exs` (61-71, 86-100),
  `ecto_details_panel_test.exs` (50-58), `n_plus_one_panel_test.exs` (134-152),
  `ecto_export_panel_test.exs` (162-177): end with one real working interaction.
- `panel_live_view_tab_test.exs:426` (rejoin race), `application_test.exs:86-93`
  (`maybe_attach(true)` too), `host_check_test.exs:107-112` (status and escaped text),
  `plugins/live_view_test.exs:427-430` (an exception was recorded),
  `truncate_test.exs` (177-185, 201-216, 221, 407-412, 424-429: a sibling value stays
  visible), `redact_config_test.exs:26-32`, `client_match_test.exs:92-94`,
  `components_test.exs:23-25`, `examples/oban_test.exs:97`, `plug_test.exs` (103, 157-161),
  `process_top_test.exs:42-45`, `process_info_test.exs:181-187`.
- JS: `export_copy.test.mjs:81-91` (arrive with matching pages so only
  `pageChanged` explains the drop), `loader.test.mjs:200-210` (assert the message).

## Batch C: shared helpers in `test/support`

- `PageHelpers.with_plugins(plugins)`: Store reset, attach, restore on exit (about 12
  copies; `sqlite_plugins/1` and `n_plus_one_panel_test` `start/1` build on it).
- `ProcessHelpers.tracked(sid, fun)` (from `collector_test`), used by the `emit`/
  `dispatch` helpers of `plugins/live_view_test`, `plugins/request_test`, `spans_test`,
  `plugins/ecto_test`; `stop_store!/0` (collector, plug, panel_live, mcp/tools);
  `dead_process/0`; `in_process/1` instead of hand-rolled spawns (`process_info_test`,
  `live_view_compat_test`); `idle_process/0` in `store_test` and `process_panel_test`.
- `PageHelpers`: `browser_headers/1` (used by `load_page`, `panel_live_test`,
  `plug_test`, `plugins/live_view_test`, `mcp/endpoint_test`), `open_tab/3` (visit,
  open panel, open tab; replaces the local `open` helpers), `visible/1`, `hidden/1`,
  `reshow/1` (`pdt:visibility`), `attribute/3`, `open_panel` with a query option
  (`panel_root/2` and inline `live(conn, "/__pdt/panel?...")`), `run_sqlite/4` and
  `query_row_seqs/1` (explain, export, details panels), `boom_view/0`.
- `test/support/mcp_helpers.ex`: `rpc/3`, `@meta`/`modern` headers, one MCP conn
  builder for `mcp/endpoint_test` (about 15 hand-built variants), `mcp_call/2`.
- `ReportFixtures`: `failing/5` (report_test, mcp/tools_test); data overrides and a
  duration so `panel_live_test` and `panel_live_view_tab_test` drop their own event builders.
- `stack_args_helpers.ex` uses `EnvHelpers`; support files renamed after their modules.
- JS: `flush` and the `navigator` override in `fake_dom.mjs`; `setup()` and `hook()`
  take overrides instead of hand-built envs.

## Batch D: exact values and selectors

- Loose assertions where the value is known: counts (`>= 5`, `trimmed > 0`,
  `count <= 5`), `=~ "boom"`, `url =~ sid`, `{:ok, _params}`, `byte_size > 0`,
  `is_integer(duration)`, the `_meta` test name, the tool count (assert the names).
- Styling class selectors (`.pdt-tag--http`, `.pdt-count`, `.pdt-changed`,
  `.pdt-eval__result`, `.pdt-vital__peak`, `.pdt-badge--warn`, `.pdt-tab--error`):
  use ids or `data-pdt-*` attributes, adding them to the templates where missing.
- Private state behind helpers or `@doc false` functions: PanelSocket and HostCheck
  logged-once keys (`reset_*` like `LiveViewCompat.reset_warnings/0`), the panel
  `seen` assign.

## Batch E: JS wiring tests

`fake_dom.mjs` `flushFrames` is unused: add DOM-level tests for the loader's pointer
drag and window resize, the panel's focus restore and tab arrow keys, and the
`PdtSummaryMore` and `PdtExport` hooks.

## Risks

- **Hot path, memory, host conflicts**: tests only, except Batch D's ids and data
  attributes (inside the panel iframe, no host CSS or JS) and `down_grace_ms`.
- **Public API**: `down_grace_ms` goes; a config that sets it logs an unknown key
  and keeps booting. CHANGELOG line.
- **Tests passing for the wrong reason**: each strengthened test is checked to fail
  when the behaviour it guards is broken (a temporary local break, not committed).
- **Flakiness**: touched files run with `mix test --repeat-until-failure 50`.
