# Phase 5f plan: message trace

Part of [the BEAM tools plan](./2026-11-09-beam-tools-roadmap-plan.md), ADR 11.
Replaces the roadmap's opt-in `handle_info` tracing: one tracer design.

## Scope

- "Trace messages" in the System tab: the messages the inspected process receives
  and sends, newest last, each redacted and truncated, with its time and, for a
  send, the receiver (a link). One trace at a time on the node; it stops by
  itself after 100 messages or 10 seconds, when the process exits, when the panel
  goes away, or on Stop.
- OTP 27+ only: a trace session (`:trace` module) never takes the global tracer
  `dbg` or `recon` may be using. On older OTPs the button is replaced by a note.
- Follows `actions:` and the protected set (ADR 10): it copies the process's
  messages, and tracing the toolbar or core processes could loop or slow the node.

## Task 1: `Tracer` (risky: tracing host processes, combined review)

`lib/phoenix_dev_toolbar/tracer.ex`, a GenServer child only when enabled:

- `available?/0`: `Code.ensure_loaded?(:trace)` (OTP 27+). `:trace` is called
  through a variable module, so OTP 26 compiles without warnings.
- `start(pid, owner)`: one trace on the node; a new one from the same owner
  replaces it, from another owner is refused (`:busy`). Creates a session with
  itself as the tracer, `:trace.process(session, pid, true, [:send, :receive])`,
  monitors the target and the owner, a 10 s timer.
- Trace messages: each one becomes `%{at_ms, dir: :in | :out, peer, message}`,
  `Truncate.redact/1` then `Truncate.inspect_value/1`; at 100 the session is
  destroyed at once. Messages already queued after the stop are dropped.
- `stop(owner)`, `status(owner)` (nil, or the pid, events, running and why it
  stopped). The session is destroyed on every stop path, and with the Tracer
  (`terminate/2`, trapping exits); a destroyed session leaves no trace flags.
- Tests (`test/phoenix_dev_toolbar/tracer_test.exs`, tagged `:trace_sessions`,
  excluded in `test_helper.exs` when `:trace` is missing): receive and send are
  recorded and redacted, the 100 cap stops it, the target exiting stops it, the
  owner exiting clears it, a second owner is busy, stop removes the trace flags
  (`:erlang.trace_info/2` on the session... or a send after stop records nothing).

## Task 2: the System tab

`#pdt-system-trace`: a "Trace messages" button (gated like Peek and on
`available?/0`), the status line (count, seconds left, why it stopped), Stop,
and the list (`#pdt-system-trace-list`). The panel reads `status/1` on its sample
tick while a trace runs or until its result was shown. Tests in
`system_panel_test.exs`, tagged too.

## Docs

ADR 11 (trace as shipped), roadmap: tick 5f and drop the Phase 4 tracing item,
CHANGELOG line.

## Risks

- **Host cost**: a traced process sends a copy of each message to the Tracer:
  bounded by the 100 cap (stopped at once) and 10 s. A flood can queue more than
  100 before the stop lands: they are dropped, never stored.
- **Loops**: tracing the Tracer, the panel or its transport is refused (protected set).
- **Leftover flags**: every stop path destroys the session, including the
  Tracer's own exit.
- **Memory**: 100 truncated events; the Tracer's mailbox drains after a stop.
