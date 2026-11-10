# Report read API: plan

Roadmap item "(S) Documented `PhoenixDevToolbar.Report` read API over the Store,
for IEx and Tidewave" (After 0.0.1). Today nothing the toolbar captures is
reachable without a browser except the Ecto JSON export. ADR 13 records the
decision.

## Scope

- `PhoenixDevToolbar.Report`, a public, documented module of pure reads over
  `Store.sessions/0`, `Store.events/1` and `NPlusOne`:
  - `sessions/1`: recent page views, newest first, filtered by `:path` (string or
    regex), `:view`, `:kind`, `:limit`
  - `latest/1`: the newest session matching the same filters
  - `summary/2`: one compact map per page: request, query totals and slowest
    queries, N+1 groups, slowest callbacks, render totals, errors, dropped events
  - `queries/2`, `callbacks/2`, `n_plus_one/2`, `errors/2`: the full lists
- A target is a sid, a session map from `sessions/1`, or a list of sids. A
  request sid includes the LiveView sessions that joined from it (`children:
  true` by default): the dead render and the connected mount are one page.
- Return values are plain maps with atom keys, documented `@type`s, times in
  microseconds, `at` as `DateTime`: never the internal `%Event{}` or `%Session{}`,
  so the Store can change without breaking callers.
- Disabled toolbar or Store not running: `[]` and `nil`, never a raise.
- ExDoc: a "Reading data" module group; README gets a short "From IEx or an
  agent" section.

Out of scope: EXPLAIN and process actions (they touch the database or other
processes), JSON encoding (the Markdown export and the MCP endpoint build on
these maps later).

## Tests (written first)

`test/phoenix_dev_toolbar/report_test.exs`, async false (named ETS tables),
events inserted through `Store.new_session/1` and `Store.insert/2`:

- sessions newest first, each filter, limit
- latest returns nil when nothing matches
- a request target includes its connected LiveView, not a LiveView it navigated to
- queries: shape, rows and error, origin, `n_plus_one?` flag, chronological
- callbacks: queries and DB time counted per span of the same sid
- n_plus_one: grouped with the configured threshold, `threshold: false` disables
- errors from the three sources
- summary: totals, slowest capped at 5, dropped and trimmed summed, nil for an
  unknown sid
- Store not running (tables missing) returns `[]` and nil

## Risks

- Hot path: none. No handler changes; reads run in the caller's process only.
- Production footprint: none. Pure functions, no process, no attach; the dep stays
  `only: :dev`.
- Memory: a read copies at most the capped events of a few sessions (ADR 03) into
  the caller. `summary/2` returns at most 5 slowest items per list.
- Host conflicts: none (no CSS, JS, CSP or LiveSocket involvement).
- Public API: this is the first read API. Shapes are documented as maps with
  stated keys; adding keys is not breaking, removing or renaming is (CHANGELOG
  line). The data is already truncated and redacted at insert (ADR 03), so the
  API exposes nothing the panel does not; raw EXPLAIN params are never returned.
- Docs and ADR sync: ADR 13 (new), ADR index, roadmap tick, CHANGELOG line.
