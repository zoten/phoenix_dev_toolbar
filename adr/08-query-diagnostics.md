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
- A group reaching the threshold is an N+1. A group is one SQL and origin: repeats in
  other callbacks or sessions (the dead render and the connected mount, every click)
  join it, counted as callbacks, with the time it last repeated. The tab's Clear button
  stores a `:n_plus_one_cleared` event in the page's session: the badge and the tab
  fold it like any other event and start over, so after a fix the developer sees
  whether the N+1 comes back. The threshold is the Ecto plugin's
  `n_plus_one:` option, 5 by default, an integer of at least 2, or `false` to turn the
  detector off.
- UI: an "N+1 ×k" badge at `:warn` (k distinct groups), the groups above the queries
  (SQL, origin, the most repeats in one callback, how many callbacks, HTTP or live, the
  last time), advice (preload or join), and an `N+1` tag on the rows from the threshold
  on.
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
  (`/*!`), no backslash (an escape in MySQL strings, not in Postgres ones), and no `;`
  separator outside quotes and comments (defence in depth: Postgrex and MyXQL prepare
  single statements, Exqlite drops a statement's tail). The prefix depends on the
  adapter: `EXPLAIN` (Postgres, MyXQL), `EXPLAIN
  QUERY PLAN` (SQLite3); other adapters get no button. Never `ANALYZE`, which runs the
  query. It runs through `repo.query/3` in a transaction that is always rolled back,
  with a 5 s timeout (and `SET LOCAL statement_timeout` on Postgres), in `start_async/3`,
  one at a time per panel; a page change cancels a running one, so it never holds a
  pool connection past its page. A plan can be hidden; a late result for a row that
  left the list is dropped. The button keeps focus while it runs (`aria-busy`) and is
  named after its query. The plan (Postgres' text lines, otherwise
  `Ecto.Adapters.SQL.format_table/1`), truncated to 8 KB, or the error, replaces the row.

**Export** (`PhoenixDevToolbar.EctoExport`, pure; the form above the Ecto tab's list).
- Two formats of the page's queries (its sids, read from the Store, oldest first):
  `short` (seq, SQL, params, location: the origin frame) and `full` (adds time, duration,
  phase HTTP or live, repo, source, result, timings, task, N+1 tag folded like the tab,
  stacktrace, and an `explain` status). Params are the stored, redacted string: the raw
  params kept for EXPLAIN are never exported.
- `full` with EXPLAIN runs `Explain.run/2` (same checks and rollback as the button) one
  query at a time, at most 50 queries within 15 s; the rest are `skipped`, non explainable
  ones carry the reason.
- **Download** is a plain link, `<path>/export/ecto.json?format=&explain=&root=&sids=`,
  relative to the panel's URL, answered by `PhoenixDevToolbar.Plug` as an attachment
  (`EctoExport.request/1`): same origin, so a host CSP's `frame-src 'self'` allows it,
  where Firefox blocks a `blob:` link clicked in the iframe. The sids (at most 4, each a
  session in the Store, the root one of them) are the access key, as for the panel. It is encoded with the
  host's JSON library (`Phoenix.json_library/0`, pretty printed when it is Jason) and runs
  in the request process, untracked, so its EXPLAINs are never recorded.
- **Copy** builds the same map in `start_async/3` (cancelled by a page change; a copy and
  a single EXPLAIN never run together: Copy is disabled while either runs) and sends it
  with `push_event/3` to the panel's `PdtExport` hook, with the page it was built from
  (its sids). A Copy refused as busy, or an export that crashes, sends `pdt:export`
  with an `error` instead, so the hook settles its clipboard write at once. The hook's
  logic lives in `export_copy.mjs` (node tested). The form carries the
  page it shows (`data-pdt-page`): the hook drops an export, arriving or held, whose page
  is no longer the form's, for example a Copy clicked before the LiveView joined, and
  asks for a new Copy.
- Both exports take their `path` from the page, or from the Store sessions when the page
  has none yet (only the request): the request's path.
- The form's choices are kept by the component, so a re-render does not reset them, and
  the Download link follows them.

## Consequences

- One click explains the exact query the page ran, with its real params, without
  copying SQL anywhere.
- The explain payload makes an Ecto event bigger: at most about 4.5 KB of params on
  top of the stored SQL, so about 2.3 MB per session under the per plugin cap.
- `ecto_sql` stays optional: `Explain` only runs for an attached Ecto plugin, and its
  reference to `Ecto.Adapters.SQL` is compiled without an undefined warning.
- Tests run EXPLAIN on a real SQLite database (`DemoWeb.SQLiteRepo`) and, when
  `PDT_POSTGRES_URL` is set (always in CI, a `postgres:17` service), on Postgres
  (`DemoWeb.PostgresRepo`, tag `:postgres`, one schema per run): typed params, the plan
  lines, the query never run, the local timeout, errors leaving the connection usable.
  `ecto_sqlite3` is a dev and test dependency, `postgrex` a test one. MyXQL is untested.

## Open limits

- Queries with map (json), tuple or other struct params, more than 50 params, or SQL
  over 8 KB cannot be explained.
- `UNION` queries starting with a parenthesis, `VALUES` and `TABLE` are not recognized
  as SELECTs.
- EXPLAIN takes a connection from the host's pool for up to 5 s, and planning takes the
  same locks as the query: it can wait behind a migration. On MySQL the 5 s timeout is
  the client's only: the server may keep waiting on a metadata lock.
- A database error is shown as the database words it, which may quote a param value
  (the export carries it too).
- EXPLAIN plans and params can quote secrets (a session token, an API key in a WHERE
  clause): the redaction covers params by key only, so the tab, the plans and both
  exports may show them. Treat an export like a log before sharing it.
- Copy starts the clipboard write in the click, with the text promised for when the
  export arrives (`ClipboardItem`), so a slow export keeps the click's user activation.
  Outside a secure context (plain http on a LAN IP) there is no Clipboard API: the
  export is copied with `execCommand("copy")` on arrival, which browsers allow only
  within about 5 s of the click; past it the export is held for a minute and the tab
  asks for a second Copy click, which copies it without a new export.
- The busy states (one EXPLAIN at a time, a Copy refused while busy, a crashed export)
  are not covered by an ExUnit test: SQLite answers too fast to observe them. The
  hook's answer to an `error` is covered by `export_copy.test.mjs`.
- The planner may evaluate functions marked IMMUTABLE with constant arguments; MySQL
  before 5.6.3 executes derived tables during EXPLAIN.
- N+1 spans follow LiveView callbacks (ADR 02), so the detector can be wrong both ways:
  - consecutive `handle_info/2` or `handle_async/3` calls that render nothing share one
    span: a poll that runs one query per tick is flagged after 5 ticks;
  - a `start_async`/`assign_async` task that outlives its callback takes the span its
    LiveView is in when it queries: a loop in it can be split across spans, and tasks
    finishing in the same gap can be merged;
  - a render's components run in their own spans.

  The row tag says "in one callback (or between two callbacks)".
- Queries run by Ecto's own tasks (parallel preloads) get a weak origin (an Enum
  frame).
- Task plumbing (`Task.Supervised`, `:proc_lib`, `Phoenix.LiveView.Async`) is skipped
  like Ecto frames. A `fn -> Repo.all(q) end` in `Task.async` or `start_async` tail
  calls the repo, so no frame of it is left: a caller-sourced query also stores
  `initial_call` (one `:"$initial_call"` read, `Mod.fun/arity`, nil for plumbing
  modules). `Report` derives `origin` as the first stacktrace frame, else
  `initial_call`, else `task in View.callback "event"` of the callback owning the
  query's `{sid, span}`, else `task in View` (a `start_async` often runs after its
  callback ended), else nil. N+1 keys stay on the stacktrace frame.
