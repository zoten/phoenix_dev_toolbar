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
  regex), `:view`, `:kind`, `:limit`; `latest/1` is the newest match.
- `summary/2` gives one compact map per page: the request, query count, failures
  and total time with the 5 slowest queries, N+1 groups, callback totals with the
  5 slowest, render totals, errors, and the events lost to the caps. The slowest
  queries, slowest callbacks and errors are briefs by default (no SQL, params,
  assigns changes, times or stacktrace; an error keeps its first frame as
  `origin`; LiveView crashes carry their stacktrace in call order, cut after the last host frame plus one, and `origin` is their first host frame, ADR 07): `verbose: true` returns the full items, `queries/2`, `callbacks/2`
  and `errors/2` the detail.
- A query's `origin` (queries, briefs, `unattributed.origins`) is the first stacktrace
  frame, else the task function (`initial_call`), else `task in View.callback "event"`
  or `task in View` for a query run inside `Task.async` or `start_async` (ADR 08).
  `queries/2`, `callbacks/2`, `n_plus_one/2` and `errors/2` return the full lists.
- LiveView emits no telemetry for `handle_info`, so a query of a `:live_view`
  session whose `{sid, span}` no `:callback` or `:render` event owns is
  unattributed (`handle_info`, a PubSub reload, or a task). `summary/2` reports
  `unattributed: %{count, total_us, origins}` (top 5 origins by time; compact
  and verbose alike), and `callbacks/2` adds inferred entries (`inferred: true`, no duration, `origin` of
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
  with the Ecto plugin's configured threshold unless `threshold:` is given.
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
- The Markdown export (roadmap) can render these maps instead of reading the
  Store itself.
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
- Assigns snapshots, client `phx:*` events and the component tree are not exposed.
