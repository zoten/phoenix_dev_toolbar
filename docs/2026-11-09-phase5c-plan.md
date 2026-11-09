# Phase 5c plan: process actions (kill, suspend, watch, message peek)

Part of [the BEAM tools plan](./2026-11-09-beam-tools-roadmap-plan.md), ADR 10.
Builds on 5a (`Protected`, `ClientPolicy`, `ProcessRef`) and 5b (System tab,
`ProcessInspector`, `ProcessView`). Two tasks.

## Scope

- **Kill** (System tab, any process; Process tab, the page's LiveView): reason
  `kill` (`:kill`, untrappable), `shutdown` (`:shutdown`) or `crash` (an exit with a
  `RuntimeError`, as a crash looks in logs and to supervisors).
- **Suspend** for 10 s (System tab): `:erlang.suspend_process/1` from a supervised
  toolbar process, resumed after the TTL, when the panel that asked goes away, or on
  Resume. Never more than 60 s, never more than 10 processes at once.
- **Watch** (System tab, any process, open to every client: it only monitors): the
  panel monitors up to 10 processes and lists each one's exit reason and time.
- **Message peek** (System tab): the first 10 messages, only while the queue holds
  fewer than 100, each redacted and truncated. Never polled.

Every destructive action (kill, suspend, peek) is refused unless `ClientPolicy`
allows this panel's client (`actions:`, loopback by default) and `Protected` allows
the target. Kill and suspend need a confirm click; one action a second per panel;
each one done is logged with `Logger.warning/1`.

## Task 1: `ProcessActions` and `Suspender` (risky: combined review)

- `lib/phoenix_dev_toolbar/process_actions.ex` (`@moduledoc false`), pure policy +
  the calls, unit tested:
  - `allowed(pid, context) :: :ok | {:error, String.t()}`: `ClientPolicy.check_actions/1`
    on `context.client` then `Protected.check/2`. Messages say what to change
    (`actions: :any` for Docker or LAN).
  - `kill(pid, reason, context)`: `reason` is one of `"kill" | "shutdown" | "crash"`
    (strings from the client, matched, never atoms from input); `Process.exit/2`;
    log line with the pid, its name and the reason.
  - `peek(pid, context) :: {:ok, [String.t()], total} | {:error, ...}`:
    `message_queue_len` first, then `Process.info(pid, :messages)` only under 100;
    the first 10, `Truncate.redact/1` + `Truncate.inspect_value/1` each.
- `lib/phoenix_dev_toolbar/suspender.ex` (GenServer, `@moduledoc false`), started in
  `PhoenixDevToolbar.Application` children only when enabled:
  - `suspend(pid, ttl_ms, owner)`: refuses when 10 are suspended, when the pid is
    already suspended by it, or `ttl_ms` out of 1000..60000. Monitors the target and
    the owner (the panel); `:erlang.suspend_process/1` rescued (dead, self).
  - Resumes on TTL, owner `DOWN`, target `DOWN` (forget), `resume/2`. Suspensions
    by a process end with it (OTP), so a crash of the Suspender resumes everything.
  - `suspended(owner) :: %{pid => deadline}` for the panel to show what it froze.
  - Calls from the panel (our process, never a host one) with a 1 s timeout,
    wrapped: a Suspender restarting answers an error, never crashes the panel.
- `ProcessInspector`: GC now and `ProcessInfo.status/2` refuse a suspended target
  (`status: :suspended`): both would wait for it to resume.
- Tests: `test/phoenix_dev_toolbar/process_actions_test.exs`,
  `test/phoenix_dev_toolbar/suspender_test.exs` (TTL resume via monitor on a short
  TTL: `assert_receive` on the status change through a probe, no sleep; owner exit
  resumes; target exit forgets; the cap; Suspender exit resumes).

## Task 2: the panel

- `PanelLive`: computes once at mount `pdt_actions = %{client: client_ip, panel: self(),
  transport: socket.transport_pid, endpoint: socket.endpoint}` and passes it to every
  tab component (`panel_layout.ex` `live_component`), internal (prefixed, not in the
  guide). Forwards `{:DOWN, ...}` messages to every tab's `handle_info/2` (a monitor
  a tab set is delivered to the panel process).
- `ProcessView.actions/1`: the kill reason select, Kill, Suspend 10 s / Resume,
  Watch, Peek; a pending confirm (`Confirm kill`, `Cancel`); disabled with the
  reason when `ProcessActions.allowed/2` refuses, the reason shown as text.
- System tab: all four actions, a "Watched" list (`#pdt-system-watched`, at most 10,
  each with its exit reason and time once down, linked while alive), a "Messages"
  section for the peek. The pending confirm and the peek drop when the target changes.
- Process tab: Kill for its target (the LiveView: the page reconnects and remounts).
- CSS in `assets/css/panel.css`, `mix assets.build`.
- Tests (`system_panel_test.exs`, `process_panel_test.exs`): kill needs a confirm and
  kills; a protected process shows the refusal and no Kill button works; a non
  loopback client (`actions: :any` vs default with a forged peer) sees actions off;
  suspend shows suspended and Resume resumes; watch shows the exit reason; peek shows
  redacted messages and refuses a long queue; killing the page's LiveView from the
  Process tab.

## Docs

ADR 10 Accepted to Implemented for actions (decision updated to what shipped),
README `actions:` example, CHANGELOG lines, roadmap tick 5c.

## Risks

- **Host crash**: the point of kill. Guarded by policy, protected set, confirm,
  rate limit, log. Suspend is the dangerous one (a frozen process holding a lock
  stalls others): TTL, owner monitor, cap, and OTP's own release on Suspender exit.
- **Panel deadlock**: GC and `:sys` on a suspended target would wait: refused.
  Suspending the panel, its transport or the Suspender: protected.
- **Memory**: watches 10, suspensions 10, peek 10 messages of a queue under 100,
  each truncated.
- **Secrets**: peeked messages redacted like assigns.
- **Hot path**: none. **Prod**: the Suspender is a child only when enabled.
- **Public API**: none; `pdt_actions` is an internal assign.

## Verification

`mix test` on the touched files per task, `mix precommit` at the end, `mix dev`:
kill a LiveView (it reconnects), suspend one (the page stops answering, comes back
after 10 s), watch and peek in the System tab.
