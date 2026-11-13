# 0.0.7: MCP feedback round plan

An agent used 0.0.6 only through the MCP endpoint (ADR 15) after two persona QA
runs on one dev server. `page_summary` answered "anything wrong here?" in one
call per page and `caller` made queries readable. These are the gaps it hit, by
impact. Target: the next release, stopping before `mix bump` (the owner runs it).

Tests first for T1 to T4, one commit per task, ADRs edited in place, one
CHANGELOG line per task (T1 says breaking).

## Tasks

### T1: compact, filterable `page_queries` (ADR 13, ADR 15)

One page with two clicks returned 287k characters from `page_queries`: full SQL,
params, `times` and 10 stack frames per row, up to 200 rows.

- `Report.queries/2` takes filter options: `callback:` (atom or string, compared
  as a string, never turned into an atom), `event:`, `span:` (a callback's seq
  group, as on callbacks), `seq_from:` and `seq_to:` (inclusive; seq is global,
  so these window a page across its sessions). Filters run after the read, so
  `n_plus_one?` still sees every query.
- MCP `page_queries` takes the same as `callback`, `event`, `span`, `seq_from`,
  `seq_to`, plus `verbose` (boolean, false). Compact rows: `seq`, `sid`, `span`,
  `callback`, `event`, `origin`, `caller`, `duration_us`, `rows`, `source`,
  `n_plus_one?`, `noise`, `error`, and `sql` cut to 160 bytes on a UTF-8
  boundary with `sql_truncated: true` when cut. `verbose: true` gives today's
  rows. `total` counts the filtered rows.
- `page_callbacks` takes `callback` and `event` too (same rule; no compact
  mode: callbacks carry no SQL).
- Tests: filters on a LiveView with two `handle_event`s; compact row keys and
  the SQL cut (multi-byte); `verbose`; a bad filter type is a tool error naming
  the argument.
- Breaking (`page_queries` default row shape): CHANGELOG says so.

### T2: queries by caller (ADR 13, ADR 15)

"Where do the 62 queries of this click go?" took `jq | sort | uniq -c`.

- `Report.query_groups(target, by, opts)`, `by` one of `:caller`, `:origin`,
  `:callback`, `:sql`; `opts` as `queries/2` (filters included). Each group:
  `key` (nil groups as `nil`), `count`, `total_us`, `n_plus_one` (how many of
  its queries are flagged), `sql` (first query's, cut as in T1, nil for
  `by: :sql`, where the key is the cut SQL). Sorted by count, then `total_us`.
  Noise is excluded unless `noise: true`.
- MCP `page_queries` `group_by` (`caller`, `origin`, `callback`, `sql`):
  returns `groups` instead of `queries`, `limit` applies to groups, `total`
  counts groups and `queries_total` the queries grouped.
- `summary/2` adds `callbacks.heaviest`: the callback with the most queries (nil
  without one), as a callback brief plus `by_caller` (top 5 caller groups of its
  span). `markdown/2` gets one "Heaviest callback" line with those callers.
- Tests: a `handle_event` whose queries come from two callers; grouping by each
  key; `heaviest` picks the most queries, not the slowest.

### T3: LiveView sessions on `list_pages` (ADR 15)

The click ran in the connected mount `uoWY...`, which `list_pages` folds into its
request: the agent only found it in `page_summary`'s `sids`.

- Each `list_pages` row gets `live_views`: the request's child LiveView sessions
  (connected mount first, then any LiveView whose parent chain leads to the
  request), each `sid`, `view`, `path`, `started_at`, `events`, at most 10, plus
  `live_views_more` when cut. Built from one `Store.sessions/0` read, not one
  per row.
- Descriptions of `list_pages` and the page tools say: pass the request sid, the
  page tools cover its LiveViews; a LiveView sid reads as its page.
- Test: a dead render plus connected mount plus a `handle_event`; the row lists
  the mount sid; `page_queries` with `event:` finds the click's queries from the
  request sid.

### T4: actor label (ADR 13, ADR 15, ADR 02)

Two testers on one server: pages were matched to personas by timestamp.

- Config `label: {Mod, :fun}` or a 1-arity function, called with the conn in
  the plug's `before_send` (the router pipeline has run, so
  `conn.assigns.current_scope` is there). It returns a string or nil; anything
  else is nil. It runs in the host's request process: wrapped in
  `try/rescue/catch`, a failure logs once per boot and yields nil. Documented as
  "read `conn.assigns` only, no queries".
- `?pdt_label=alice` on any tracked request sets a `_pdt_label` cookie
  (`http_only`, `same_site: Lax`, path `/`, session lifetime) and labels that
  request; `?pdt_label=` (empty) clears it. Parsed from `conn.query_string`
  only when it contains `pdt_label=`. Precedence: param, cookie, `label:`.
- The label is sanitized (printable, at most 64 bytes, cut on a UTF-8 boundary)
  and stored on the request `Session` (new `label` field, written with one ETS
  update). LiveView sessions inherit it through `parent` at read time: no
  hot path change.
- Read side: `Report` sessions and `summary.session` carry `label`;
  `list_pages` rows show it and take a `label` filter (exact match);
  `markdown/2` puts it in the heading; the panel's Request tab shows it.
- Tests: `label:` function, MFA, raising function (nil, logged once), param
  sets and clears the cookie, precedence, a connected mount inherits the label,
  `list_pages` filter, a 200-byte label is cut.
- `dev.exs`: a `label:` reading a fake current user so `mix dev` shows one.

### T5: MCP reachability (ADR 15, README, guides/agent-setup.md)

`.mcp.json` resolved `${PHX_IP}` at agent start while the server listened on
127.0.0.1: every call was a bare `ECONNREFUSED`, which the toolbar cannot see.

- The first tracked request per boot logs one info line with the MCP URL built
  from that request's scheme, host and port (the address the browser reached),
  plus the endpoint's bound `ip` when it is loopback: "MCP at
  http://localhost:4000/__pdt/mcp (listening on 127.0.0.1 only: an MCP URL
  with another address is refused)". Once per boot (`:persistent_term` flag),
  never when `mcp: false`.
- README and the guide: one line, "the MCP URL must use an address the server
  listens on: bind `0.0.0.0` (`http: [ip: {0, 0, 0, 0}]`) or use the same
  `PHX_IP` in both", next to the existing `ECONNREFUSED` notes.
- Test: the log line appears once, with and without loopback binding.

### T6: docs sync and review

`usage-rules.md`, the skill (`usage-rules/skills/phoenix-dev-toolbar-report/SKILL.md`:
the drill-down goes summary, `heaviest`, `page_queries` with `group_by: "caller"`
and `event`, then `verbose` rows), the `audit_page` prompt, ADR 13 and 15
tables, README MCP section, CHANGELOG. Then the `feature-review` skill over the
range and `mix precommit` plus `agent-tools/ci-min.sh`.

No screenshot: the panel change is one text field in the Request tab.

## Risks

- **Hot path**: no telemetry handler changes. T4's `label:` runs in the plug's
  `before_send`, in the host's request process, once per tracked page request:
  rescued, logged once, and documented as assigns-only. Cookie and param parsing
  only when present. T5 is one `:persistent_term` read per tracked request.
- **Production footprint**: none; the plug stays inside `code_reloading?`, the
  cookie is only set on dev requests that carry the param, `label:` is never
  called while disabled.
- **Memory bounds**: the label is at most 64 bytes per request session (capped
  sessions). `list_pages` `live_views` at most 10 per row. Groups are computed at
  read time from capped events.
- **Host conflicts**: the `_pdt_label` cookie name is prefixed and only set on
  request; a host reading all cookies sees it in dev. `pdt_label` stays in the
  host's `params` (we do not strip it): a host that rejects unknown params sees
  it, documented.
- **Privacy**: a label may hold an email; it lives only in the dev Store (TTL)
  and the MCP is local by default (ADR 15). Docs suggest an id or a persona name.
- **Public API**: breaking `page_queries` default shape (T1); additions:
  `queries/2` filters, `query_groups/3`, `summary.callbacks.heaviest`, session
  `label`, `label:` config, `list_pages` `live_views` and `label`. ADR 13 and 15,
  usage rules, skill and prompt stay in sync.
- **Tests and ADRs**: tests first; ADR 02 (session fields), 13, 15 edited in
  place; `Config` validates `label:` with a boot warning on a bad value.
