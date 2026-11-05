# ADR 03: Event Storage: Bounded ETS Ring Buffers

**Status:** Implemented (2026-11-05)  
**Area:** storage  
**Related:** [ADR 02](./02-telemetry-collection-and-correlation.md) (writers), [ADR 04](./04-ui-delivery.md) (readers)

## Context

Events are produced by many host processes concurrently and read by the panel
LiveView. LiveView sockets live for hours in development, so any per-session
buffer grows without bound unless capped. A GenServer as the write path would
serialize every query of the app behind one mailbox.

## Decision

- `PhoenixDevToolbar.Store` is a GenServer that **owns** the ETS tables but is not on
  the write path. All tables are named, `:public`, with `read_concurrency` and
  `write_concurrency`:

  | Table | Type | Row |
  |---|---|---|
  | `:pdt_events` | `ordered_set` | `{{sid, seq}, %Event{}}` |
  | `:pdt_sessions` | `set` | `{sid, %Session{}, count, dropped}` |
  | `:pdt_pids` | `set` | `{pid, sid}` (`$callers` attribution, ADR 02) |
  | `:pdt_socket_ids` | `set` | `{socket_id, sid}` (dead render to LiveView) |
  | `:pdt_transports` | `set` | `{transport_pid, sid}` (newest sid per browser tab) |
  | `:pdt_rate` | `set` | `{{sid, second}, n}` (flood guard) |

  `seq` comes from a shared `:atomics` counter, so per-session order is insertion order.
- Writers (host processes) insert directly (a missing table, while the Store restarts,
  also means `:no_session`): flood check (`update_counter` on `:pdt_rate`),
  `update_counter` of the session `count` (a missing session means `:no_session` and
  the event is discarded), then the event row. Results: `:ok | :dropped | :no_session`.
- Per-session cap: when `count` first exceeds `max_events` (and every 64 inserts after
  that) the writer casts `{:trim, sid}`; the Store deletes the oldest events and loops
  until the session is back within the cap, since inserts may race with the trim.
- Session cap: on every new session the Store evicts sessions beyond `max_sessions`,
  those without a live LiveView owner first, then the oldest by `started_at`, so the
  open tab survives a burst of page loads.
- LiveView sessions are monitored; `down_grace_ms` after `:DOWN` the session and its index
  rows are deleted, unless a rejoining LiveView claimed it in the meantime (`claim/3`).
- TTL sweep every `sweep_ms`: sessions without a live LiveView owner (requests, orphans)
  are deleted when their last event (or start) is older than `ttl_ms`. An idle open tab
  keeps its data. The sweep also drops stale rate windows, orphan events, index rows
  whose session is gone, and pid and transport rows of processes that exited.
- Limits, overridable with `config :phoenix_dev_toolbar, limits: [...]` and kept in
  `:persistent_term` for the write path:

  | Key | Default |
  |---|---|
  | `max_events` | 500 per session |
  | `max_sessions` | 50 |
  | `events_per_second` | 200 per session |
  | `ttl_ms` | 10 minutes |
  | `sweep_ms` | 30 seconds |
  | `down_grace_ms` | 60 seconds |

- Payloads are truncated before insert by `PhoenixDevToolbar.Truncate`:
  `inspect(value, limit: 50, printable_limit: 1024)` for assigns and params, SQL capped at
  8 KB (UTF-8 safe), stacktraces at 10 frames without toolbar and `:telemetry` frames.
  Keys whose name contains an entry of `config :phoenix_dev_toolbar, redact: [...]`
  (default `["password", "token", "secret"]`, case insensitive) become `"[REDACTED]"`;
  redaction is bounded in depth (6) and width: only the first 50 items of a list and
  the first 50 entries of a map (iteration order) are walked.
- Live updates: our own `Registry` (`PhoenixDevToolbar.Registry`, duplicate keys) keyed
  by sid. Writers `Registry.dispatch/3` a `{:pdt_event, sid}` notification (no payload);
  the panel reads from ETS and throttles re-renders to every 100 ms. No dependency on
  the host's `Phoenix.PubSub`.
- When the toolbar is disabled the Store does not start and no table exists.

## Consequences

- Memory is bounded by roughly `sessions x events x truncated size`, a few MB at most.
- Writers never block on a process; the cost is one or two ETS writes.
- Data is lost on restart and code reload of our app, which is fine for a dev tool.

## Open limits

- Limits are global, not per plugin: a chatty plugin can push others' events out.
- Redaction walks only the first 50 entries of large maps: a sensitive key further in is
  hidden by the inspect limit in practice, not by redaction.
