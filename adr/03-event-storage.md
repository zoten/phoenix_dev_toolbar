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
  | `:pdt_sessions` | `set` | `{sid, %Session{}, count, dropped, trimmed}` |
  | `:pdt_pids` | `set` | `{pid, sid}` (`$callers` attribution, ADR 02) |
  | `:pdt_socket_ids` | `set` | `{socket_id, sid}` (dead render to LiveView) |
  | `:pdt_transports` | `set` | `{transport_pid, sid}` (newest sid per browser tab) |
  | `:pdt_rate` | `set` | `{{sid, second}, n}` (flood guard) |
  | `:pdt_counts` | `set` | `{{sid, plugin}, count, trimmed}` (per plugin cap) |

  `seq` comes from a shared `:atomics` counter, so per-session order is insertion order.
- Writers (host processes) insert directly (a missing table, while the Store restarts,
  also means `:no_session`): flood check (`update_counter` on `:pdt_rate`),
  `update_counter` of the session `count` (a missing session means `:no_session` and
  the event is discarded), `update_counter` of the plugin's `count`, then the event
  row. Results: `:ok | :dropped | :no_session`.
- Caps, per plugin and per session: when a plugin's `count` first exceeds `max_events`
  (and every 64 inserts after that) the writer casts `{:trim, sid, {:plugin, id}}`, so
  a chatty plugin (LiveView events on a `phx-change` form) only trims its own events.
  When the session `count` exceeds `max_session_events` it casts `{:trim, sid,
  :session}`, which trims the oldest events of any plugin: many plugins stay bounded.
  The Store deletes the oldest events of that scope (a match on the session's range,
  at most `max_session_events` rows) and loops until it is back within the cap, since
  inserts may race with the trim. Deleted events are added to `trimmed`, per plugin
  and per session, and the panel shows "N older trimmed" next to "+N dropped", so
  lists that start later than the page are never silent.
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
  | `max_events` | 500 per plugin and session |
  | `max_session_events` | 2000 per session |
  | `max_sessions` | 50 |
  | `events_per_second` | 200 per session |
  | `ttl_ms` | 10 minutes |
  | `sweep_ms` | 30 seconds |
  | `down_grace_ms` | 60 seconds |

  Each override must be a positive integer (`ttl_ms` and `down_grace_ms` may be 0). An
  unknown key or an invalid value (`:infinity` would disable a cap) is logged at boot
  and keeps its default: the host always boots.

- Payloads are truncated before insert by `PhoenixDevToolbar.Truncate`:
  `inspect(value, limit: 50, printable_limit: 1024)` for query and path params, SQL capped at
  8 KB (UTF-8 safe), other text (exception messages and banners) at 2 KB, stacktraces at
  10 frames without toolbar and `:telemetry` frames. Every `inspect/2` in a collector uses
  these limits, including plug options and thrown or exited reasons.
  Keys whose name contains an entry of `config :phoenix_dev_toolbar, redact: [...]`
  (default `["password", "token", "secret"]`, case insensitive) become `"[REDACTED]"`;
  redaction is bounded in depth (6) and width: only the first 50 items of a list, the
  first 50 entries of a map (iteration order) and tuples of up to 50 elements are
  walked (tuples too since the BEAM tools: queued messages and results are tuples; it
  runs in collectors in host processes, at the same bounded cost as lists).
- LiveView assigns and params can be huge (preloaded lists), so they go through
  `Truncate.preview/3` instead: at most 200 nodes and 20 items per container are walked,
  whatever is not walked becomes `"…"` (so a sensitive key past the budget is cut, never
  shown), then `inspect(limit: 20, printable_limit: 256)` capped at 360 bytes per value.
  A `:callback` event stays around 4 KB at most.
- One payload is kept raw, by size instead of truncation: the params an Ecto SELECT
  needs for EXPLAIN (ADR 08), at most 50 scalars and 4 KB of binaries (copied), never
  rendered. An Ecto event stays under about 13 KB (8 KB of SQL, the params, the rest
  truncated).
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

- Limits are the same for every plugin: a plugin cannot ask for a larger buffer.
- When `plugins × max_events` exceeds `max_session_events` (5 or more busy plugins at
  the defaults), the page ceiling trims the oldest events of any plugin, so a chatty
  plugin can again push out a quiet one.
- A host process killed between the counter bump and the event insert leaves its
  counters one above the stored rows: that scope settles at `max - 1` events.
- Redaction walks only the first 50 entries of large maps: a sensitive key further in is
  hidden by the inspect limit in practice, not by redaction.
