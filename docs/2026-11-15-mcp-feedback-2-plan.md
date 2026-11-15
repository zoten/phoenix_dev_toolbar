# 0.0.7: second MCP feedback round plan

The agent from the first round (`2026-11-13-mcp-feedback-plan.md`) kept using
0.0.6 through the MCP endpoint (ADR 15) in implementation and review subagents.
Most of its report is fixed in `[Unreleased]` already: `page_queries` compact
rows, filters and `group_by`, `live_views` on `list_pages`, the boot log line
with the MCP URL. This batch covers what is left and small enough to ship with
0.0.7. The stdio wrapper (connecting when the server is down or restarts) is
its own decision: [ADR 17](../adr/17-mcp-stdio-wrapper.md), Proposed.

Tests first, one commit per task, ADRs edited in place, one CHANGELOG line per
task (T2 says breaking). Stop before `mix bump` (the owner runs it).

## Tasks

### T1: hard cap on tool results (ADR 15)

`page_queries(verbose: true, limit: 200)` can still return hundreds of KB, past
an agent's tool result limit. Today nothing bounds the encoded size.

**Config.** `mcp: [max_result_bytes: 60_000]` (the default), a positive
integer or `:infinity` (no cap). It sits next to `clients:` in the `mcp:`
keyword (`true` keeps meaning the defaults). A bad value logs one boot warning
and counts as the default (`Config`, as the other `mcp:` options). The cap is
measured on the JSON text block, applied in `MCP.Tools.run/4`
(`lib/phoenix_dev_toolbar/mcp/tools.ex:235-240`) after `Json.safe/1`; the
plug passes the configured value in `opts`.

**Cutting.** Over the cap, the tool's row list (`pages`, `queries`, `groups`,
`callbacks`, `errors`, `assigns`) is cut from the end (keeping the order the
tool chose) until the result fits; `returned` is updated and the result gets
`truncated: true`, `next_offset` (where the cut happened) and `hint`: "result
cut to N of M rows to stay under 60000 bytes. For the rest call again with
offset: N; for everything in one result pass max_bytes (or max_bytes: 0 for no
cap); or narrow it with filters, group_by, a lower limit, or without verbose".
`page_summary` lists (`slowest`, `errors`, ...) are cut the same way, longest
first (no `next_offset`: the hint points to `page_queries`, `page_callbacks`
and `page_errors` for the full lists). `page_report` Markdown is cut on a UTF-8
boundary with a closing line saying so, before the footer (the footer and its
`panel_url` always stay). A single row larger than the cap leaves an empty list
with the hint.

**Full data on request.** Two per-call arguments on every tool that returns
rows (`list_pages`, `page_queries`, `page_callbacks`, `page_errors`,
`recent_errors`, `page_assigns_shape`) and on `page_summary` and `page_report`:

- `offset` (non-negative integer, 0): skips that many rows (after filters,
  sort and `group_by`), so an agent pages through a large result in cap-sized
  calls. `total` stays the full count. `page_summary` and `page_report` take no
  `offset`.
- `max_bytes` (non-negative integer): this call's cap instead of the configured
  one; `0` means no cap. It can raise or lower the cap; the configured value is
  the default, not a ceiling (the client is already allowed, ADR 15, and the
  agent knows its own tool result limit).

**Where an agent reads about it.** The `offset` and `max_bytes` property
descriptions in the tool schemas (what an agent sees first), the `hint` itself,
the shipped skill (`usage-rules/skills/phoenix-dev-toolbar-report/SKILL.md`: "a
`truncated` result: page with `next_offset`, or pass `max_bytes`, or write the
full result to a file with the `curl` recipe and `max_bytes: 0`"),
`usage-rules.md`, the `audit_page` prompt (one line), `guides/agent-setup.md`,
the README MCP section and its config list, and ADR 15. T5 checks all of them.

**Tests.** `page_queries` verbose over the cap is cut with `truncated`,
`next_offset` and `hint`, `returned` matches; a second call with `offset:
next_offset` returns the next rows; `max_bytes: 0` returns every row; a lower
`max_bytes` cuts earlier; `mcp: [max_result_bytes: :infinity]` never cuts, a
bad value warns at boot and uses the default; a result under the cap has no
`truncated` key; `page_report` keeps its footer when cut; `offset` past the end
returns `[]`; a negative `offset` or `max_bytes` is a tool error naming the
argument.

### T2: compact sessions in MCP results (ADR 15)

`owner` (a pid string) is noise for an agent in every `list_pages` row and in
`page_summary.session`.

- MCP only (`Report` keeps the field): `list_pages` rows, their `live_views`,
  and `page_summary` sessions drop `owner` unless `verbose: true`
  (`page_summary` has it; `list_pages` gets `verbose`, boolean, false).
- `panel_url` stays: it is one string and the link the agent hands to the
  developer (ADR 14).
- Tests: no `owner` by default, present with `verbose`.
- Breaking (default row shape): CHANGELOG says so.

### T3: `view` filter on `list_pages` (ADR 15)

The agent searched four sids for "the registration LiveView".

- `view` (string, exact module name as `inspect/1` prints it, such as
  `"DemoWeb.PageLive"`, at most 256 bytes, never turned into an atom): a row
  matches when its own `view` or one of its `live_views` has that view. Combines
  with `path`, `path_prefix`, `label`, `since`. Applied in `pages/2`
  (`tools.ex:565`) and `with_live_views/2` (`tools.ex:679`), on the same single
  Store read.
- Tool description: "newest page for a path or view: `limit: 1`".
- Tests: a dead render plus connected mount of one view and a page of another;
  `view` returns only the first; combines with `path`; an unknown view returns
  `[]`, not an error.

### T4: MCP without an MCP client (README, guides/agent-setup.md, skill)

Subagents often do not inherit the parent's MCP connection. The endpoint is
stateless JSON-RPC over HTTP (no `initialize` needed), so `curl` works today.

- A test first: a `tools/call` with no prior `initialize` and no
  `MCP-Protocol-Version` header returns the result as JSON in the text block.
- `guides/agent-setup.md`, a "Without an MCP client (subagents, scripts)"
  section: a `curl` + `jq -r '.result.content[0].text'` recipe for
  `page_summary` and `page_queries` with `group_by`, plus "load the page first
  with `curl -H 'Accept: text/html'`" (dead render only: no connected mount, no
  events).
- The same recipe, shorter, in the shipped skill
  (`usage-rules/skills/phoenix-dev-toolbar-report/SKILL.md`), `usage-rules.md`
  and the README MCP section: "brief subagents with this recipe".

### T5: docs sync and review

ADR 15 tool table, the `mcp:` options and Open limits (add: no headless "GET as a user and
wait for the mount" helper, a dead render via `curl` is the substitute; captures
live in memory, so a before/after comparison needs both pages in one server
lifetime, save `page_summary` JSON to diff across restarts), ADR 13 if `Report`
changes, the `audit_page` prompt if it names removed keys, CHANGELOG. Then the
`feature-review` skill over the range, `mix precommit` and
`agent-tools/ci-min.sh`.

No screenshot: no panel change.

## Out of scope

- `last_event(view:, event:)`: `list_pages(view:, limit: 1)` then
  `page_queries(event:, group_by: "caller")` is two calls.
- Named baselines that persist or come from another server: the Store is
  in memory by design (ADR 03). Revisit if it comes back.
- The stdio wrapper: ADR 17, its own batch once accepted.

## Risks

- **Hot path**: none; every change is on the MCP read side, in the MCP request
  process.
- **Production footprint**: none; no new entry point.
- **Memory bounds**: T1 encodes the result once to measure it, then cuts and
  re-encodes at most a few times (halving), bounded by the existing row limits.
  Prefer measuring row sizes once over repeated full encodes. `max_bytes: 0`
  and `:infinity` give back today's unbounded size, still bounded by the row
  `limit` caps and the Store caps (ADR 03).
- **Host conflicts**: none (no CSS, JS, routes or config).
- **Public API**: breaking `list_pages` and `page_summary` default shape (T2);
  additions `truncated`, `next_offset`, `hint`, `offset` and `max_bytes` on
  the row tools, `mcp: [max_result_bytes:]` config, `list_pages` `view` and
  `verbose`. Clients
  must reconnect to see the new arguments (ADR 15, Upgrades). ADR 15, usage
  rules, skill and prompt stay in sync.
- **Tests and ADRs**: tests first; ADR 15 edited in place; T4's docs claim is
  backed by its test.
