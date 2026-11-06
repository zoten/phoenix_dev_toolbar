# ADR 08: Query Diagnostics: N+1 Detector and EXPLAIN

**Status:** Implemented (2026-11-06)  
**Area:** ui  
**Related:** [ADR 02](./02-telemetry-collection-and-correlation.md) (callback spans), [ADR 03](./03-event-storage.md) (the explain payload's bounds), [ADR 05](./05-plugin-behaviour.md) (the Ecto plugin and its tab)

## Context

The Ecto tab lists what ran. The usual questions on a slow page are why: the same
query repeated once per row (N+1), or a query the database runs badly. Both answers
need data the tab did not have: which LiveView callback a query ran in, and the
params needed to replay a query.

## Decision

**N+1 detector** (`PhoenixDevToolbar.NPlusOne`, pure, folded event by event in the
panel: in the Ecto summary for the badge and in the Ecto tab for the list).
- A group is the same SQL from the same origin in one callback span of one session
  (`Event.span`, ADR 02). The origin is the first stacktrace frame outside Ecto,
  DBConnection and the repo: it needs the repo's `stacktrace: true`; without it the
  SQL alone is the key and the tab says so.
- A group reaching the threshold is an N+1. The threshold is the Ecto plugin's
  `n_plus_one:` option, 5 by default, an integer of at least 2, or `false` to turn the
  detector off.
- UI: an "N+1 ×k" badge at `:warn` (k groups detected), the groups above the queries
  (SQL, origin, count, HTTP or live), and an `N+1` tag on the rows from the threshold on.
- Bounds: counts for the last 4 spans of each sid (processes of one sid, nested
  LiveViews, interleave their spans), at most 500 distinct queries per span, keyed by
  a hash of SQL and origin; at most 50 groups kept, newest first, with the true total.

**EXPLAIN** (`PhoenixDevToolbar.Explain`).
- Capture, in `collect/3` (the host process): a query whose SQL starts with `SELECT`
  or `WITH` (after whitespace and comments) and is stored whole (8 KB, ADR 03) keeps
  its dumped `params` (what the driver received, not `cast_params`) in
  `data.explain`, when they are at most 50 scalars and 4 KB of binaries in all:
  integers, floats, booleans, nil, binaries (copied, so a sub-binary does not keep its
  parent alive), date and time structs, `Decimal`, `Duration`, `Postgrex.Interval`,
  `Postgrex.INET`, and one level of arrays of those (each array and element counts).
  Anything else stores why it cannot be explained. The raw params are never rendered.
  Cost: about 1 µs per tracked query.
- Run, from the Ecto tab: a button on each explainable row. The browser sends only the
  row's seq; the component reads that event back from the Store, from this page's sids
  only, and `Explain.run/2` checks it again: an Ecto query of a configured repo that
  succeeded (the database parsed that SQL as the query it ran, so the prefix can only
  explain it: a failed query could hide a comment that turns the prefix into `EXPLAIN
  ANALYZE`), with captured params, a `SELECT` or `WITH`, no MySQL versioned comment
  (`/*!`), and no `;` separator outside quotes and comments (defence in depth: Postgrex
  and MyXQL prepare single statements, Exqlite drops a statement's tail). The prefix depends on the adapter: `EXPLAIN` (Postgres, MyXQL), `EXPLAIN
  QUERY PLAN` (SQLite3); other adapters get no button. Never `ANALYZE`, which runs the
  query. It runs through `repo.query/3` in a transaction that is always rolled back,
  with a 5 s timeout (and `SET LOCAL statement_timeout` on Postgres), in `start_async/3`,
  one at a time per panel; a page change cancels a running one, so it never holds a
  pool connection past its page. The plan (Postgres' text lines, otherwise
  `Ecto.Adapters.SQL.format_table/1`), truncated to 8 KB, or the error, replaces the row.

## Consequences

- One click explains the exact query the page ran, with its real params, without
  copying SQL anywhere.
- The explain payload makes an Ecto event bigger: at most about 4.5 KB of params on
  top of the stored SQL, so about 2.3 MB per session under the per plugin cap.
- `ecto_sql` stays optional: `Explain` only runs for an attached Ecto plugin, and its
  reference to `Ecto.Adapters.SQL` is compiled without an undefined warning.
- Tests run EXPLAIN on a real SQLite database (`DemoWeb.SQLiteRepo`); `ecto_sqlite3` is
  a dev and test dependency.

## Open limits

- Queries with map (json), tuple or other struct params, more than 50 params, or SQL
  over 8 KB cannot be explained.
- `UNION` queries starting with a parenthesis, `VALUES` and `TABLE` are not recognized
  as SELECTs.
- EXPLAIN takes a connection from the host's pool for up to 5 s, and planning takes the
  same locks as the query: it can wait behind a migration. On MySQL the 5 s timeout is
  the client's only: the server may keep waiting on a metadata lock.
- A database error is shown as the database words it, which may quote a param value.
- The busy state (one EXPLAIN at a time) is not covered by a test: SQLite answers too
  fast to observe it.
- The planner may evaluate functions marked IMMUTABLE with constant arguments; MySQL
  before 5.6.3 executes derived tables during EXPLAIN.
- N+1 spans follow LiveView callbacks: a render's components run in their own spans,
  and work in `handle_info/2` shares the span of the gap it runs in.
- Queries run by Ecto's own tasks (parallel preloads) get a weak origin (a Task or
  Enum frame).
