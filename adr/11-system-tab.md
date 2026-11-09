# ADR 11: System Tab

**Status:** Accepted  
**Area:** ui  
**Related:** [ADR 09](./09-process-panel.md) (the page centric Process tab), [ADR 10](./10-process-addressing-and-actions.md) (addressing, actions), [ADR 05](./05-plugin-behaviour.md) (a built-in plugin)

## Context

The Process tab answers questions about the page's processes. Many problems live
elsewhere: a leaking GenServer, a supervisor with a growing child list, a process
with a backed up queue. Developers open observer for this, which needs a GUI and a
second tool. The Process tab should stay small and page centric.

## Decision

A built-in plugin, `PhoenixDevToolbar.Plugins.System` (`:system`, tab "System"), in
`:defaults` after Process. It attaches no telemetry and reads nothing until a process
is inspected. The Process and System tabs share the inspected process's state and
polling (`ProcessInspector`), its rendering (`ProcessView`) and their options
(`ProcessOptions`: `sample_ms`, `samples`, `relations_ms`, ADR 09 bounds).

- **Which process**: a pid (`#PID<0.1.0>`, `<0.1.0>`, `0.1.0`) or registered name
  typed in the search box, or a link: a relation here, or any process in the Process
  tab (`Panel.navigate/3`). Every reference goes through `ProcessRef` (ADR 10).
  Errors say why: not a pid, no such name, another node, exited.
- **Breadcrumbs**: each process inspected, at most 20, oldest dropped, the same
  process twice in a row once. A crumb is clicked by its index; going back to one
  drops those after it.
- **Inspector**: the ADR 09 data (vitals, sparklines, details, relations, GC now),
  polled only while shown and visible, plus, with the relations: who started it
  (`$ancestors`, else `:parent` on OTP 25+, 20 at most, each a link) and its current
  stacktrace (as deep as `backtrace_depth`, 20 frames at most).
- **State**: for processes started through `proc_lib`, a "Read state" button runs
  `:sys.get_status/2` in `start_async/3`: 1 s timeout, once a second at most. Only a
  process waiting in a `gen` loop (gen_server, gen_statem, gen_event, supervisors,
  LiveViews) or hibernated is asked; a Task, a plain process or a server busy in a
  callback is refused before anything is sent, so no system message is ever left
  in a mailbox that never reads it. Its `format_status` applies; the state is taken
  from the status's `State` entry, redacted with the `redact` keys and truncated like
  assigns. A `format_status/2` that lists its own entries instead (a LiveView: its
  view, parent, transport, topic, component count) shows them one per line, each
  value redacted; any other shape is not shown.
- **Trees**: backwards, the ancestors chain. Forwards, the supervision subtree,
  expanded lazily: `count_children` first, a paged list above 200 children, never
  `which_children` on a large supervisor. Whole node: applications, then each
  application master's top supervisor, host applications first, OTP ones collapsed.
  Every supervisor call runs in `start_async/3` with a timeout.
- **Top**: the 50 processes with the most memory, reductions since the last sample, or
  the longest queue, sampled on demand or periodically only while shown. The sweep
  runs in a task and stops past a process count cap, saying so.
- **Message trace**: opt-in, one pid at a time, through a trace session (OTP 27+) so
  it never takes the global tracer from `dbg` or `recon`; rate limited, stopped after
  N messages or T seconds, payloads truncated.

## Consequences

- One more default tab; free until a process is inspected.
- Reading state runs the target's `format_status`: a slow one costs up to the
  timeout, in a task, never in the panel.
- A server busy in a callback when asked reads as busy: try again.

## Open limits

- Trees beyond the ancestor chain, the process top and the message trace are not
  built yet (roadmap 5d to 5f).
- A `proc_lib` process that hibernates without being a `gen` server is asked for its
  state and never answers: the read times out and the message stays.
- On an OTP before 26.2 (no single dictionary key reads) ancestors fall back to
  `:parent` and the state button never shows.
- Message trace before OTP 27 (no trace sessions): either skipped or uses the global
  tracer with a warning, to settle in its phase plan.
