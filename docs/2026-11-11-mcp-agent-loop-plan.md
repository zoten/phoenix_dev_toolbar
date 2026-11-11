# MCP agent loop plan

The MCP endpoint (ADR 15) answers "what did this page do". An agent's real loop
is: measure, change code, reload, measure again, compare. These tasks make that
loop one or two tool calls, add a cross-page error view, a Markdown report and
an assigns shape, and ship one MCP prompt. All tools stay read-only.

One task per commit, tests first, ADRs edited in place, one CHANGELOG line each.
Combined reviewer only for T5 (it calls into a host LiveView process).

## Tasks

### T1: `since` cursor on `list_pages` (ADR 13, 15)

- `Report.sessions/1` gets `since:`: a sid (pages that started after it) or a
  `DateTime`. An unknown sid is `[]`, never a raise.
- `list_pages` gets `since` (a sid, or an ISO 8601 timestamp parsed with
  `DateTime.from_iso8601/1`; anything else is a tool error). Each page already
  carries its start time: check it is in the JSON as ISO 8601, add it if not.
- No code reload epoch: Phoenix's reloader emits no telemetry and a Mix
  `after_compiler` hook does not outlive one compile run. The agent passes the
  sid it measured before its edit.
- Tests: `test/phoenix_dev_toolbar/report_test.exs`, `mcp/tools_test.exs`.

### T2: `compare_pages` (ADR 13, 15)

- `Report.compare(before, after, opts)`: two targets in, a delta out, built from
  two `summary/2` results (caller's process):
  - `queries`, `callbacks`, `renders`: `before`, `after`, `delta` of `count` and `total_us`
  - `n_plus_one`: `fixed` and `new`, matched on SQL plus origin
  - `errors`: `fixed` and `new`, matched on source plus message
  - `unattributed`: count and `total_us` delta
  - nil when either side is gone
- MCP `compare_pages`: `before` (sid, required), and `after` (sid) or `path`
  (the newest page at that path started after `before`; default: `before`'s
  own path). Result carries both `panel_url`s.
- New typedoc `comparison`. Tests first: a page with an N+1 against the same
  page without it (harness LiveView in `test/support`).

### T3: `recent_errors` (ADR 13, 15)

- `Report.errors/1` over every session when given `:all`, or a new
  `Report.recent_errors(opts)`: `since:` (sid or `DateTime`), `limit:`, newest
  first, each error with its `sid` and session `path`.
- MCP `recent_errors`: `since`, `limit` (1..100, 20); each item has `panel_url`.
- Tests: errors on two different pages, one from a LiveView `handle_info`.

### T4: Markdown page report (ADR 13, 15, roadmap)

- `Report.markdown(target, opts)` (public, `@doc`, `@spec`): the compact summary
  as Markdown: request line, query and callback totals, N+1 table, slowest
  queries and callbacks tables, errors with first frames, unattributed origins.
  Pure string building over `summary/2`; SQL in fenced blocks, every cell
  escaped for `|` and newlines, bounded by the summary's own caps.
- MCP `page_report`: `sid`, `path`; returns the Markdown as the text block and
  `{"sid", "panel_url", "markdown"}` as `structuredContent`.
- Panel: a "Copy as Markdown" action next to the existing export, through the
  same `push_event/3` clipboard path as `EctoExport` (`lib/phoenix_dev_toolbar/ecto_export.ex`).
  Its JS gets a DOM-level test (ADR 06).
- Tick "Page-level Markdown export" in the roadmap.

### T5: `page_assigns_shape` (ADR 07, 15)

- Reuses the panel's snapshot path (`lib/phoenix_dev_toolbar/panels/live_view.ex`
  around line 244: `Phoenix.LiveView.Debug.socket/1` then `Truncate.snapshot/1`),
  extracted into one function both callers use. It runs in a `Task` with a short
  timeout from the MCP request process, never in the LiveView.
- Result per assign: key, type (`list`, `map`, `struct Mod`, ...), `length` for
  lists and maps, approximate words (`:erts_debug.flat_size/1` on the untruncated
  value, computed inside the task) and a `stream?` flag. No values.
- Only for a LiveView whose owner is alive; otherwise a tool error saying the
  page must be open.
- Tests: a LiveView holding a 1000 item list, assert it ranks first by size.

### T6: MCP prompt `audit_page` (ADR 15)

- `prompts/list` and `prompts/get` in `lib/phoenix_dev_toolbar/mcp/protocol.ex`;
  `initialize` advertises `prompts` capability. One prompt, `audit_page(path)`:
  call `page_summary`, then `page_n_plus_one`, `page_queries` sorted slowest,
  `page_errors`, `page_assigns_shape` for LiveViews; report findings with the
  `panel_url`. Both protocol eras; protocol tests.
- Update `@instructions` to mention `since` and `compare_pages`.

### T7: docs sync and review

ADR 13 and 15 tables, `usage-rules.md`, the skill
(`usage-rules/skills/phoenix-dev-toolbar-report/SKILL.md`), `guides/agent-setup.md`
(the before/after loop), roadmap. Final feature review, `mix precommit`,
`agent-tools/ci-min.sh`, and a dogfood pass on `mix dev`: measure a harness
page, add an N+1, reload, `compare_pages`.

## Risks

- **Hot path**: none. Every task reads the Store from the MCP request process
  or the panel. No new telemetry handler, no capture change.
- **Host processes**: T5 makes a synchronous `Debug.socket/1` call to a host
  LiveView, as the panel does: inside a `Task` with a timeout, the
  `flat_size` walk inside the same task, a dead or busy LiveView is a tool
  error. Combined reviewer on this task.
- **Production footprint**: none; no new entry point or dependency.
- **Memory bounds**: all results derive from capped events and capped summaries;
  `recent_errors` and `page_assigns_shape` (100 keys, `Truncate.snapshot/1`)
  are limited; the Markdown is bounded by the summary caps.
- **Redaction**: T5 returns no values; T4 only renders already redacted strings.
- **Host conflicts**: T4's copy button lives in the panel iframe only.
- **Public API**: new `Report` functions and options, new tools and keys:
  additive (ADR 15 contract). `@doc` and `@spec` on each.
- **Protocol**: T6 adds a capability; old clients ignore it. Both eras tested.
- **LiveView versions**: T5 relies on `Phoenix.LiveView.Debug.socket/1`, already
  used by the panel; run `agent-tools/ci-min.sh`.
