# ADR 03: Event Storage: Bounded ETS Ring Buffers

**Status:** Accepted  
**Area:** storage  
**Related:** [ADR 02](./02-telemetry-collection-and-correlation.md) (writers), [ADR 04](./04-ui-delivery.md) (readers)

## Context

Events are produced by many host processes concurrently and read by the panel
LiveView. LiveView sockets live for hours in development, so any per-session
buffer grows without bound unless capped. A GenServer as the write path would
serialize every query of the app behind one mailbox.

## Decision

- `PhoenixDevToolbar.Store` is a GenServer that **owns** ETS tables but is not on
  the write path:
  - `:pdt_events`: `:ordered_set`, `:public`, `write_concurrency` + `read_concurrency`,
    key `{sid, seq}`, value `%PhoenixDevToolbar.Event{}`. `seq` comes from a shared
    `:atomics` counter, so per-session order is insertion order.
  - `:pdt_sessions`: `:set`, sid metadata (owner pid, started at, event count, dropped count).
  - `:pdt_pids`: `:set`, `pid -> sid` index for `$callers` attribution.
- Writers (telemetry handlers) insert directly, then increment the session counter
  with `:ets.update_counter/4`. When a session exceeds its cap, the oldest events are
  trimmed by the Store asynchronously (a `cast` with the sid, deduplicated).
- Limits (configurable): 500 events per session, 50 sessions overall (oldest evicted),
  idle TTL 10 minutes, sweep every 30 seconds. The Store monitors LiveView owner pids
  and drops their session 60 seconds after `:DOWN` (grace for reconnects).
- Flood guard: a per-session events-per-second budget (default 200) using `:atomics`;
  over budget, events are dropped and counted, and the panel shows "N dropped".
- Payloads are truncated before insert: `inspect(value, limit: 50, printable_limit: 1024)`
  for assigns and params, SQL capped at 8 KB, stacktraces at 10 frames. Keys listed in
  `config :phoenix_dev_toolbar, redact: [...]` (default `[:password, :token, :secret]`)
  are replaced with `"[REDACTED]"`.
- Live updates: our own `Registry` (`PhoenixDevToolbar.Registry`, duplicate keys) keyed
  by sid. Writers `Registry.dispatch/3` a `{:pdt_event, sid}` notification (no payload);
  the panel reads from ETS and throttles re-renders to every 100 ms. No dependency on
  the host's `Phoenix.PubSub`.

## Consequences

- Memory is bounded by roughly `sessions x events x truncated size`, a few MB at most.
- Writers never block on a process; the cost is one or two ETS writes.
- Data is lost on restart and code reload of our app, which is fine for a dev tool.

## Open limits

- Limits are global, not per plugin: a chatty plugin can push others' events out.
