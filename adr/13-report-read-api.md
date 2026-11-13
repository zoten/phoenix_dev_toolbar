# ADR 13: Report Read API

**Status:** Implemented (2026-11-10)  
**Area:** integration  
**Related:** [ADR 02](./02-telemetry-collection-and-correlation.md) (sessions and callback spans), [ADR 03](./03-event-storage.md) (what the Store holds and for how long), [ADR 08](./08-query-diagnostics.md) (the N+1 detector it reuses)

## Context

Everything the toolbar captures is shown in the panel and nowhere else, except
the Ecto tab's JSON export. A developer in IEx, or a coding agent that evaluates
code in the running app (Tidewave's `project_eval`, a remote shell), cannot ask
"how many queries did `/posts` run, and is there an N+1?" without a browser.
The Store's functions answer it, but they are internal: their shapes (`%Event{}`
with a free-form `data` map, `%Session{}` with pids and counters) change with
the plugins.

## Decision

`PhoenixDevToolbar.Report` is a public, documented module of pure reads over the
Store, built for IEx and agents:

- `sessions/1` lists page views newest first, filtered by `:path` (string or
  regex), `:view`, `:kind`, `:label` (exact), `:limit`, `:since` (a sid, read as its page root, or a `DateTime`: only
  sessions that started after that page; an unknown sid gives `[]`); `latest/1` is the
  newest match.
- **Actor label**: sessions and `summary.session` carry `label` (a string or nil), who the
  page belongs to when several people or personas share one server. The plug resolves it in
  `before_send` (the host's request process, once per tracked page): the `?pdt_label=`
  param, else the `_pdt_label` cookie, else the `label:` config (`{Mod, :fun}` or a
  1-arity function of the conn, reading `conn.assigns` only). `?pdt_label=alice` sets the
  cookie (`http_only`, `SameSite=Lax`, `Secure` over https, path `/`, session lifetime); an empty `?pdt_label=`
  clears it and falls through to `label:`. The param is read from `conn.query_string` and
  the cookie from the raw `cookie` header, only when they contain the name (no
  `fetch_query_params` or `fetch_cookies`, which mutate the host conn); `pdt_label` stays in
  the host's params. A failing `label:` function (raise, throw, exit) logs once per boot
  and yields nil, a non-string return is nil, an invalid `label:` value is a boot warning.
  The label is cleaned (control characters stripped, trimmed, at most 64 bytes cut on a
  UTF-8 boundary, empty is nil) and written on the request session with one ETS update;
  a LiveView session copies its parent's label on creation (one lookup, so it outlives
  a swept request) and reads fall back to `parent` (at most 10 hops). Integers and atoms
  become text (an id works), booleans and nil give none; text is cut to 256 bytes before
  cleaning, and format characters (bidi overrides, zero width) are stripped too.
  `sessions(label: "alice")` filters by exact match, `markdown/2` shows it in the heading
  and the Request tab on the response row. A label may hold personal data (an email):
  prefer an id or a persona name; it lives only in the dev Store until it expires.
- `summary/2` gives one compact map per page: the request, query count, failures
  and total time with the 5 slowest queries, N+1 groups, callback totals with the
  5 slowest and `callbacks.heaviest` (the real callback with the most counted (noise free) queries, tie: more query time, nil when none ran a query; a callback brief plus its `span` and `by_caller`, the top 5 callers of its queries as `caller`, `count`, `total_us`), render totals, errors, and the events lost to the caps. The slowest
  queries, slowest callbacks and errors are briefs by default (no SQL, params,
  assigns changes, times or stacktrace; an error keeps its first frame as
  `origin`; LiveView crashes carry their stacktrace in call order, cut after the last host frame plus one, and `origin` is their first host frame, ADR 07; an error carries `stack_args`, the call arguments of its frames, only when the developer set `stack_args: [agents: true]`, ADR 03): `verbose: true` returns the full items, `queries/2`, `callbacks/2`
  and `errors/2` the detail.
- `recent_errors/1` lists the newest failures of every session the Store holds (a bounded read of its capped sessions), newest first, as error briefs plus `at`, the session `path`, `page_sid` (the root: a connected mount reads as its request) and `since:` (sid: errors after that page started, the page's own sessions, request and connected mount, never listed, so a fixed page shows none of its old crashes and its tab emitting later does not hide other pages; `DateTime`: errors after it) and `limit:` (20, `nil` for all). It sees crashes in `handle_info` or another tab that no page lookup points at.
- `markdown/2` renders a page as Markdown for an agent or a bug report (nil when gone), from `summary/2` with `verbose: true` (the slowest queries need their SQL; nothing beyond the summary caps): heading with path and view, request line, totals, N+1, slowest queries and callbacks, the heaviest callback with its callers, unattributed origins and the first 20 errors (source, message and origin, not frames; the rest counted). Empty sections are left out. Captured text (SQL, messages, origins) is one inline code span per table cell, capped at 300 characters, with `|` escaped; other text is escaped so it never reads as Markdown or HTML. SQL that is long or multi-line goes in a fenced block under its table (a fence longer than any backtick run inside). With the `panel_url:` option it ends with a footer naming the page's sid and the link. The panel's "Copy as Markdown" (ADR 04) and MCP `page_report` (ADR 15) return it with the footer.
- `compare/3` puts two targets side by side, built from two compact `summary/2`
  calls (options pass through; a connected mount reads as its request, via `PageLookup.root/1`, the one place of that rule for compare, recent_errors and the MCP tools; nil when
  either side is gone): `queries`, `callbacks`, `renders` and `unattributed` as
  `%{before, after, delta}` of `count` and `total_us` (delta is after minus
  before), `n_plus_one` and `errors` as `%{fixed, fixed_total, new, new_total,
  still}`. Matching is by key, ignoring line numbers: N+1 on SQL plus origin,
  errors on source plus origin plus the first message line with pids,
  references, ports and digit runs normalized. Lists hold distinct keys (an
  error carries its `count`), at most 20; the totals count all. `before` and
  `after` carry `kind` and `sids`; a `warning` says when the kinds or session
  counts differ (live navigation, a request without its mount).
- A query's `origin` (queries, briefs, `unattributed.origins`) is the first stacktrace
  frame, else the task function (`initial_call`), else `task in View.callback "event"`
  or `task in View` for a query run inside `Task.async` or `start_async` (ADR 08).
  `queries/2`, `callbacks/2`, `n_plus_one/2` and `errors/2` return the full lists. `queries/2` takes filters, applied after the read so `n_plus_one?` still sees every query: `callback:` (atom or string, compared as a string, never turned into an atom), `event:`, `span:` and `seq_from:` / `seq_to:` (inclusive); `callbacks/2` takes `callback:` and `event:`. `query_groups(target, by, opts)` groups the queries by `:caller`, `:origin`, `:callback` or `:sql` (options as `queries/2` plus `noise:`, default false: framework queries are left out): each group has `key` (nil stays nil), `count`, `total_us`, `n_plus_one` (its flagged queries) and `sql` (the first query's, cut to 160 bytes; nil for `:sql`, whose key is the cut SQL), most queries first, then most time. The `:callback` key is the callback name plus the quoted event (`handle_event "withdraw"`), so two clicks stay apart.
- Each query also carries `caller` (the web-layer frame above the origin, ADR 08),
  `noise` (framework queries, ADR 08) and where it ran: `callback` and `event` of the
  `:callback` (else `:render`) event owning its `{sid, span}`; for a LiveView
  session no event owns, `:handle_info` or `:async` as the inferred entries below;
  for a request, `:request` (the plug pipeline, a controller). Briefs keep
  `callback` and `caller`. `summary.queries` counts, times and lists the queries
  without noise and adds `noise: %{count, total_us}`, so `compare/3` deltas ignore
  it too; `markdown/2` adds one "framework queries not counted" sentence, and
  `Callback` and `Caller` columns to the slowest queries (the caller only where it
  differs from the origin).
- LiveView emits no telemetry for `handle_info`, so a query of a `:live_view`
  session whose `{sid, span}` no `:callback` or `:render` event owns is
  unattributed (`handle_info`, a PubSub reload, or a task). `summary/2` reports
  `unattributed: %{count, total_us, origins}` (top 5 origins by time; compact
  and verbose alike), and `callbacks/2` adds inferred entries (`inferred: true`, `duration_us: nil`, never 0, so a sum or sort must default it; `origin` of
  their first query): one per `{sid, span}` and source, `callback: :handle_info`
  for queries run by the LiveView process, `callback: :async` for task queries
  (`assign_async`, `start_async`, `Task.start`, those with `caller?`), split
  where two consecutive queries are more than 100 ms apart. Limit: several
  `handle_info` within 100 ms in one span merge into one entry, and a
  `handle_info` that runs no query is invisible. `summary.callbacks` counts and
  times real callbacks only. Request sessions are never unattributed.
- A target is a sid, a session map or a list of sids. A request target includes
  the LiveView sessions whose parent it is (its connected mount, `children: true`
  by default), so one call covers the dead render and the connected mount. Live
  navigation is not followed: a navigated LiveView has a LiveView parent.
- Return values are plain maps with atom keys and documented types, times in
  microseconds, timestamps as `DateTime`. The internal structs never leak, so the
  Store and the plugins can change shape behind the API. Adding a key is not a
  breaking change; renaming or removing one is (a CHANGELOG line).
- Callbacks carry the number and time of the queries run in them, matched by
  `{sid, span}` (ADR 02), tasks included through `$callers`.
- N+1 groups and the `n_plus_one?` flag reuse the Ecto tab's fold (ADR 08),
  with the Ecto plugin's configured threshold unless `threshold:` is given. A group
  adds `ran_in` (its last 10 spans, newest first, as `sid`, `span`, `seq` of the
  owning callback or nil, `view`, `component`, `callback`, `event` and the `count`
  reached there) and `callers` (the distinct `caller` frames of its queries in those
  spans with counts, top 5). `markdown/2` shows both as N+1 columns.
- Reads run in the caller's process and touch nothing else: no GenServer call,
  no telemetry handler change. While the toolbar is disabled, or the Store is
  not running, every function returns `[]` or `nil`.
- The package ships `usage-rules.md` and an agent skill,
  `usage-rules/skills/phoenix-dev-toolbar-report/SKILL.md`, in the `usage_rules`
  layout: host apps pull them with `mix usage_rules.sync`. The documented config is
  skills-only (`skills: [package_skills: [...]]`): a `file:` sync rewrites the host's
  whole `usage-rules` block, which `phx.new` fills with Phoenix's rules.
  `guides/agent-setup.md` is a step by step install, with checks, for coding agents
  (dependency, plug, MCP, skill). The skill teaches the
  before and after routine (reach the running VM, trigger the page, read
  `summary/2`, check status and dropped events, compare). Both are part of the
  API's docs: a renamed key or function changes them too.
- Read-only by design: EXPLAIN and process actions stay in the panel, behind
  their own policies (ADR 08, ADR 10). Raw EXPLAIN params are never returned.

## Consequences

- Agents and IEx users can verify a change against real data ("the N+1 on
  `/posts` is gone, 23 queries became 3") without a browser in the loop.
- The Markdown export is a render of these maps (`markdown/2`), not a second
  reader of the Store.
- MCP clients read the same maps through the toolbar's MCP endpoint (ADR 15).
- Agents that drive a browser read the same values off the panel's `data-pdt-*`
  attributes, named after these keys (ADR 14).
- The API is a contract: changing an event's `data` keys in a built-in plugin
  now needs a matching change in `Report`, covered by its tests.
- Only what the Store still holds is readable (caps and TTL, ADR 03): a page
  older than the TTL is gone.

## Open limits

- Reaching the running node is up to the caller: a fresh `mix run` starts another
  VM with an empty Store. IEx in the dev server, a remote shell, Tidewave or the
  MCP endpoint (ADR 15) work.
- Plugin events other than the built-ins (`:ecto`, `:request`, `:live_view`)
  have no Report shape.
- `since` excludes sessions that start in the same microsecond as the cursor.
- `started_at` is wall-clock time: a clock step back can hide pages from `since`.
- `Report.sessions(since: sid)` includes that request's own connected
  mount (`list_pages` drops mounts).
- `recent_errors` copies every captured event of up to 50 sessions per call (bounded, on demand).
- `compare` `still` is a count only: an N+1 group dropping from 50 repetitions to 10 shows as still.
- Timings differ between two captures of the same page (cache, JIT, load): `compare` deltas of `total_us` are indicative, counts are exact.
- `recent_errors` has no path filter: filter the result by `path`.
- A raw Repo query failure in `recent_errors` has no callback context (the source is `:ecto`, no view or callback).
- In the Markdown a dead render's and a connected mount's `mount` and `handle_params` rows look alike (same view and callback): the report does not say which session ran them.
- `compare` reads at most 50 N+1 groups per side (summary cap): a larger set can yield false fixed or new.
- Assigns snapshots, client `phx:*` events and the component tree are not exposed.
