# ADR 11: System Tab

**Status:** Implemented (2026-11-09)  
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
- **State**: for processes started through `proc_lib`, and only for clients the
  `actions:` policy allows (it copies the process's data, ADR 10), a "Read state" button runs
  `:sys.get_status/2` in `start_async/3`: 1 s timeout, once a second at most. Only a
  process waiting for its next message at a `gen` receive point (gen_server,
  gen_statem, gen_event, supervisors, LiveViews) or hibernated is asked; a Task
  (even one blocked in a call), a plain process or a server busy in a callback is
  refused before anything is sent. Its `format_status` applies; the state is taken
  from the status's `State` entry, redacted with the `redact` keys and truncated like
  assigns. A `format_status/2` that lists its own entries instead (a LiveView: its
  view, parent, transport, topic, component count) shows them one per line, each
  value redacted; any other shape is not shown.
- **Trees** (`ProcessTree`): backwards, the ancestors chain. Forwards, a supervisor's
  children (only processes whose `$initial_call` is a `:supervisor` or a
  `DynamicSupervisor` are asked: a GenServer would crash on the request), read when
  it is selected and on Refresh, never polled: `count_children` first, then
  `which_children` only at 200 children or fewer (the most of specs and active: a
  `simple_one_for_one` has one spec), else counts only. Each child's pid is a link,
  so the tree is walked by navigation. Whole node: with nothing selected the tab
  lists the started applications (at most 100), the host's and its deps' first, then
  Elixir's, then OTP's (collapsed), each with its top supervisor as a link; the
  Applications button brings the list back. Every call has a 1 s timeout or runs in
  a task killed after it (`application_master` answers without one), always in
  `start_async/3`.
- **Top** (`ProcessTop`): in the start view, the 50 processes with the most memory,
  the most reductions per second (two sweeps 500 ms apart) or the longest queue,
  read on the Read click (once a second at most), never polled; each one a link.
  A sweep is `process_info/2` of every process (no call, no message), in a task:
  a process busy on another scheduler delays the task, never the panel. Above
  100 000 processes (`:process_count`, checked before listing) nothing is read and
  the panel says how many there are.
- **Message trace** (`Tracer`, a toolbar child only when enabled): "Trace messages"
  records what the inspected process receives and sends, oldest first, each with
  its time, its direction and, for a send, the receiver (a link), redacted and
  truncated. Through an OTP 27 trace session, so it never takes the global tracer
  `dbg` or `recon` may be using; on older OTPs a note replaces the button. One trace
  on the node at a time (another panel is told it is busy); it stops by itself
  after 100 messages or 10 s, when the process exits or the panel goes away, on
  Stop, and when the tab inspects another process. Every stop destroys the
  session, and so does the Tracer's own exit; trace messages queued after a stop
  are dropped at once. It follows `actions:` and the protected set (ADR 10): it
  copies messages, and tracing the toolbar or core processes could loop. The
  panel reads it on its sample tick.

## Consequences

- One more default tab; free until a process is inspected.
- Reading state runs the target's `format_status`: a slow one costs up to the
  timeout, in a task, never in the panel.
- A server busy in a callback when asked reads as busy: try again.

## Open limits

- A flood can queue many trace messages before the session stops: each one is a
  copy the traced process pays for, bounded by the 10 s TTL, and dropped unread.
- `:memory` of a process with a huge message queue walks that queue: the sweep
  slows down for it.
- In a release, or wherever deps live under `:code.root_dir/0`, every application
  is grouped as OTP.
- A `proc_lib` process that hibernates without being a `gen` server is asked for its
  state and never answers: the read times out and the message stays.
- On an OTP before 26.2 (no single dictionary key reads) ancestors fall back to
  `:parent` and the state button never shows.
- No message trace before OTP 27 (no trace sessions).
