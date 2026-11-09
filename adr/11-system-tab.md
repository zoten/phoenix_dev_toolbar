# ADR 11: System Tab

**Status:** Proposed  
**Area:** ui  
**Related:** [ADR 09](./09-process-panel.md) (the page centric Process tab), [ADR 10](./10-process-addressing-and-actions.md) (addressing, actions), [ADR 05](./05-plugin-behaviour.md) (a built-in plugin)

## Context

The Process tab answers questions about the page's processes. Many problems live
elsewhere: a leaking GenServer, a supervisor with a growing child list, a process
with a backed up queue. Developers open observer for this, which needs a GUI and a
second tool. The Process tab should stay small and page centric.

## Decision

A built-in plugin, `PhoenixDevToolbar.Plugins.System` (`:system`, tab "System"), in
`:defaults` after Process. It attaches no telemetry and reads nothing until shown.
The Process and System tabs share one process inspector component.

- **Inspector**: any pid or registered name (ADR 10): the ADR 09 data plus
  `current_stacktrace`, ancestors (`$ancestors`, `:parent` on OTP 25+), and for OTP
  processes `:sys.get_state` and `:sys.get_status` in `start_async/3` with a timeout,
  truncated and redacted.
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

- One more default tab; free until opened.
- `:sys` calls are synchronous: a busy process delays the inspector, never the panel.

## Open limits

- Message trace before OTP 27 (no trace sessions): either skipped or uses the global
  tracer with a warning, to settle in its phase plan.
