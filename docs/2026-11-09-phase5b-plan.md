# Phase 5b plan: System tab, inspector for any process

Part of [the BEAM tools plan](./2026-11-09-beam-tools-roadmap-plan.md), ADR 11 (and
ADR 10 for addressing). Builds on 5a: `ProcessRef`, `Panel.navigate/3`,
`ProcessView`. Three tasks, each under ~40 turns.

## Scope

- A new default tab **System** (`PhoenixDevToolbar.Plugins.System`, `:system`), after
  Process. Empty until someone types a pid or name, or follows a link.
- The inspector shows what the Process tab shows (vitals, sparklines, details,
  relations, GC now) plus: **ancestors**, **current stacktrace**, and an on demand
  **state** read (`:sys.get_status/2`) for OTP processes.
- **Links**: every local process in a relations list is a link. In the Process tab it
  opens the System tab (`Panel.navigate/3`); in the System tab it inspects in place.
  The Process tab's target pid (header) links too. No other tab renders pids today.
- **Breadcrumbs** in the System tab: at most 20, oldest dropped. Following a link or
  searching pushes; clicking crumb `i` goes back to it and drops what came after.

Not in 5b: actions (5c), trees beyond the ancestor chain (5d), top (5e).

## Task 1: extract the shared inspector state (refactor, low risk)

- New `lib/phoenix_dev_toolbar/process_inspector.ex` (`@moduledoc false`): the
  per target state and polling that `lib/phoenix_dev_toolbar/panels/process.ex` holds
  today, as functions over a LiveComponent socket, parameterised by the panel module
  and id (for `Panel.send_after/4`):
  - assigns: `selected, about, sample, relations, series, timers, gc, gc_at, gc_note, gc_timer`
  - `init/1` (the assigns of `mount/1`), `select/2` (lines 145 to 159),
    `poll_now/1`, `handle_tick/2` (the `{kind, token}` clause of `handle_info/2`),
    `schedule/2`, `cancel_timers/1`, `gc/1` and `gc_done/2` (the `"gc"` event and
    `handle_async(:gc, ...)`), `gc_ready/1`.
  - Each panel decides when it polls (`polling?/1` stays in the panel: shown and visible).
- Options: `sample_ms`, `samples`, `relations_ms` validation moves from
  `lib/phoenix_dev_toolbar/plugins/process.ex` into `PhoenixDevToolbar.ProcessOptions`
  (`init/1`, `config/1`). Process and System both use it, same defaults.
- The Process panel keeps only its targets (page sids, index select) and calls the
  inspector. `test/phoenix_dev_toolbar/process_panel_test.exs` passes untouched.

## Task 2: new reads in `ProcessInfo` (risky: combined review)

All in `lib/phoenix_dev_toolbar/process_info.ex`, unit tested in
`test/phoenix_dev_toolbar/process_info_test.exs`.

- `ancestors(pid) :: [%{id, name, pid?}]`: `$ancestors` (one dictionary key, as
  `dictionary/2` already does), registered names resolved with `Process.whereis/1`
  (names are atoms already: no atom created), plus `Process.info(pid, :parent)` on
  OTP 25+ when there is no `$ancestors`. At most 20 entries.
- `stacktrace(pid) :: [String.t()]`: `Process.info(pid, :current_stacktrace)`,
  formatted with `Exception.format_stacktrace_entry/1`, at most 20 frames. Toolbar
  frames are kept (unlike `Truncate.stacktrace/2`): here they are the truth.
  Read once per target and on every relations tick.
- `otp?(pid) :: boolean`: started through `proc_lib` (`$initial_call` and
  `$ancestors` in its dictionary). Only those answer system messages.
- `status(pid, timeout) :: {:ok, String.t()} | {:error, :not_otp | :timeout | :dead | :self}`:
  - refuses non OTP processes **before** sending anything: a plain process never
    answers, and the `:system` message would stay in its mailbox forever
  - refuses `self()` (the panel asking itself would deadlock)
  - `:sys.get_status(pid, 1000)`, `catch :exit`; the result redacted
    (`Truncate.redact/1`) and rendered with `Truncate.inspect_value/2` (its limits).
  - Called only from `start_async/3` in the panel, never polled: one click, one read,
    at most one a second (the GC rate limit pattern).
- `about/1` gains `otp?`.

## Task 3: the System plugin and panel

- `lib/phoenix_dev_toolbar/plugins/system.ex`: `use PhoenixDevToolbar.Plugin, id: :system, name: "System"`,
  `init/1` from `ProcessOptions`, no telemetry, `collect/3` returns `:skip`,
  `panel/0`. Added to `@defaults` in `lib/phoenix_dev_toolbar/config.ex:13` after Process.
- `lib/phoenix_dev_toolbar/panels/system.ex`:
  - Search form `#pdt-system-search` (`phx-submit`), input `name="ref"`, parsed with
    `ProcessRef.parse/1`; its errors (`:invalid`, `:not_found`, `:remote`, `:dead`)
    shown in `#pdt-system-error`.
  - `handle_info({:navigate, %{"pid" => ref}})` and the in-tab `"inspect"` event both
    go through `ProcessRef.parse/1`: a link is client input like any other.
  - Breadcrumbs `#pdt-system-crumbs`, each `%{pid, label}`; a click sends its index
    (`"crumb"`), never a pid.
  - Sections: header (name, pid, initial call, traps exits), `ProcessView.vitals`,
    `#pdt-system-ancestors`, `#pdt-system-stacktrace`, `ProcessView.relations`,
    `#pdt-system-state` with a "Read state" button (OTP only).
  - Polling exactly like the Process tab: only while shown and visible.
- `lib/phoenix_dev_toolbar/process_view.ex`: `relations/1` and `relation_list/1` take
  `link` (event name or nil) and `target` (`@myself`); a `:process` relation that is
  not on another node renders as a button with `phx-value-pid={relation.id}`.
  Process panel: `link="inspect"` handled by `Panel.navigate(socket, :system, %{"pid" => id})`.
- Tests: `test/phoenix_dev_toolbar/system_panel_test.exs`, one workflow per test
  (LiveViewTest against the panel, as `process_panel_test.exs` does):
  search by registered name; bad input shows the error; a relation link inspects in
  place and pushes a crumb; a crumb click goes back; "Read state" on a
  `start_supervised!` GenServer shows its state with a redacted `password` key; a
  plain spawned process shows no state button. In `process_panel_test.exs`: a
  relation click switches to the System tab with that process.

## ADR and docs updates

- ADR 11: decision updated to what shipped (status read through `get_status`, OTP
  only, rate limited); status Accepted until 5d/5e land, then Implemented.
- ADR 09: relations are links to the System tab.
- ADR 05: `:defaults` lists System.
- README: the System tab in the defaults and its options.
- CHANGELOG: `System tab: inspect any process, ancestors, stacktrace, state (ADR 11)`.
- Roadmap: tick 5b.

## Risks

- **Hot path**: no telemetry; all reads happen in the panel process while shown.
- **Host process cost**: `:current_stacktrace` and dictionary keys are cheap
  `process_info` reads. `:sys.get_status` runs code in the target (its
  `format_status/1`): on demand only, 1s timeout, rate limited, OTP only.
- **Stuck mailbox**: a `:system` message to a non OTP process is never consumed.
  Guarded by `otp?/1` before sending; test it.
- **Memory**: status output capped by `Truncate.inspect_value/2`; crumbs capped at 20;
  stacktrace at 20 frames; ancestors at 20.
- **Secrets**: state can hold credentials: redacted with the configured `redact` keys,
  like assigns (ADR 07).
- **Atoms**: all references go through `ProcessRef`; ancestors only read atoms that exist.
- **Defaults**: one more default tab, free until opened (no Store reads even).
- **Public API**: none new. `ProcessView` and `ProcessInspector` stay internal.

## Verification

- Per task: `mix test <files>`, `mix compile --warnings-as-errors`.
- End: `mix precommit` all green; `PORT=4001 mix dev`: open System, search
  `code_server`, follow a link from the Process tab, read a GenServer's state, use
  the breadcrumbs.
