---
name: phoenix-dev-toolbar-report
description: "Use when verifying how a Phoenix page behaves at runtime with phoenix_dev_toolbar: counting queries, finding or confirming the fix of an N+1, timing LiveView callbacks, or checking a page for errors after a code change. Reads PhoenixDevToolbar.Report inside the running dev server, or through the toolbar MCP tools."
---

# Verify a page with PhoenixDevToolbar.Report

Measure a page before and after a change, and report numbers instead of
assumptions. Full API: the `PhoenixDevToolbar.Report` docs.

## When to use

- You changed how a page loads data, a context function it calls, or a LiveView
  callback, and want to confirm the effect.
- The user says a page is slow or runs too many queries.
- Before claiming "the N+1 is fixed", "fewer queries" or "no errors".

## 1. Reach the running app

The data lives in the dev server's VM (`mix phx.server` or `mix dev`, in dev).

- With the `phoenix-dev-toolbar` MCP server configured: call its tools
  instead of the Elixir below: `page_summary` (`path: "/posts"`) for step 3,
  `page_n_plus_one`, `page_queries` (compact rows, SQL cut to 160 bytes; `verbose: true` for full ones; filters `callback`, `event`, `span`, `seq_from`, `seq_to`; `group_by` `caller`, `origin`, `callback` (keys like `DemoWeb.PageLive handle_event "save"`, `(dead render)` for the request's own render) or `sql` returns counts per group; drill down with `page_summary`, its `callbacks.heaviest`, `page_queries` with `group_by: "caller"` and the `event`, then `verbose: true` rows), `page_callbacks` (`sort: "slowest"`; filters `callback`, `event`) and
  `page_errors` for the details, `page_report` for a Markdown page to paste
  (`Report.markdown/2`), `page_assigns_shape` for big lists in assigns that
  should be streams (live read: the page must be open; `live_view_sid`, `note`
  and `warning` say which LiveView was read). `compare_pages` gives each side
  its `panel_url` (`before.panel_url`, `after.panel_url`). The `audit_page`
  prompt (`path`) chains them for one page. Same keys as `Report`. No VM access needed.
- With Tidewave: run the code below through `project_eval`.
- With only a browser tool: skip the Elixir below and read the standalone
  panel, `http://localhost:4000/__pdt/panel?path=/posts`, through its
  `data-pdt-*` attributes (see the package's usage rules).
- Otherwise: a remote shell (`iex --sname probe --remsh app@<host>`), which needs
  the server started with a node name (`iex --sname app -S mix phx.server`), or
  ask the user to run it in the IEx session that started the server.
- Never `mix run` or a fresh `iex -S mix`: another VM, nothing captured.

Check first: for the Elixir paths, `PhoenixDevToolbar.enabled?()` must be `true`. For MCP, a `ping` or a `list_pages` call that works is the check.
A tool or field named here but missing from your MCP tool list means the
client connected before a `phoenix_dev_toolbar` upgrade: ask the user to
reconnect it (`/mcp` in Claude Code).

## 2. Trigger the page

- Dead render: `curl -s -o /dev/null -H "Accept: text/html" http://localhost:4000/posts`.
  Without `Accept: text/html` the request is not recorded. Pages behind login
  need the user's session cookie (`-b "_my_app_key=..."`), or ask the user to
  load the page in their browser.
- A LiveView event (click, form submit) needs a real browser: a browser
  automation tool, or ask the user to do it.

## 3. Read the baseline

```elixir
alias PhoenixDevToolbar.Report
page = Report.latest(path: "/posts")
Report.summary(page)
```

Check, in this order:

- `request.status`: a 302 to a login page measured the redirect, not the page.
- `dropped` and `trimmed`: above 0 means events were lost to the caps, so a
  missing query or N+1 proves nothing.
- `errors`, `n_plus_one`, `queries.count`, `queries.total_us`,
  `queries.slowest`, `callbacks.slowest`, `unattributed`: queries of a
  LiveView page no callback owns (`callbacks/2` lists them as `inferred: true`:
  `:handle_info` for queries of the LiveView process, such as PubSub reloads,
  `:async` for task queries, such as `assign_async` or `start_async`; their
  `duration_us` is nil, so sum or sort with a default).
  `queries` counts leave out framework noise (`Phoenix.Ecto.CheckRepoStatus`,
  counted in `queries.noise`; `callbacks.heaviest` is the callback with the most
  queries plus its top callers, and `Report.query_groups(page, :caller, event: "save")`
  counts queries per caller). These items are compact (no SQL,
  params or assigns): use `queries/2` and `callbacks/2`, or `summary(page,
  verbose: true)` (`page_summary` with `verbose: true`), for the detail.

`latest/1` can pick up a page the user opened in another tab. When unsure, use
`Report.sessions(path: "/posts", limit: 5)` (over MCP, `list_pages` with
`path: "/posts"`; several testers on one server: filter by `label`, the actor each page
carries) and keep the session whose
`started_at` follows your trigger. For a before/after check, remember the sid
you measured, then use `Report.compare(sid, after_sid)`, or `Report.sessions(since: sid)` (it lists the request's own connected mount too; over MCP, `list_pages`
with `since`; a `list_pages` row also shows its connected mounts in `live_views`, and the request sid covers them in every page tool). Over MCP the loop is: `page_summary`, note the sid, edit,
reload, `compare_pages(before: sid)`; in Elixir, `Report.compare(before_sid,
after_sid)` returns the same deltas.

## 4. Change the code, trigger again, compare

Re-run steps 2 and 3 (code reloading applies the change on the next request)
and compare: `compare_pages(before: sid)` over MCP, `Report.compare(before_sid,
after_sid)` in Elixir (deltas, N+1 and errors fixed or new; mind its
`warning`). Report the delta: "/posts: 23 queries (21 ms) ->
3 queries (4 ms), N+1 on `comments` gone". Also check `recent_errors` (`Report.recent_errors(since: sid)`) after a change (a sid cursor means after that page started and never lists that page's own crashes): it shows crashes in `handle_info` or other tabs that the page does not.

## Going deeper

- `Report.n_plus_one(page)`: repeated SQL with its `origin` (the calling line),
  `ran_in` (the callbacks it repeated in: `view`, `callback`, `event`, `seq`,
  `count`) and `callers` (the distinct `caller` frames with counts). `caller`
  (also on each query) is the LiveView, controller or `on_mount` frame above
  the Repo call: for a check repeated by a shared helper, the callers say
  which pages trigger it, in one call.
  `origin` (also on queries, briefs, inferred callbacks and errors) is the first
  app stack frame, else the function a task was started with, else
  `task in View.callback` or `task in View`. `nil` usually means the repo lacks
  `stacktrace: true` in `config/dev.exs`, but a `start_async` query can still
  have a nil N+1 origin.
- `Report.callbacks(page)`: each LiveView callback with its duration and the
  `queries` and `query_us` it caused; find the expensive `mount` or
  `handle_event`.
- `Report.queries(page)`: every query with SQL, params, rows and timings, the
  `callback` and `event` it ran in (`:request` outside any LiveView callback),
  `caller`, and `noise` (`"check_repo_status"` or `"framework"` for queries
  the framework runs on every dev request; nil for the app's own).
- `Report.errors(page)`: request exceptions, failed callbacks and renders,
  failed queries. A crash's call arguments (`stack_args`) are absent unless the
  developer enabled `stack_args: [agents: true]`: do not ask for them. The panel, including
  its standalone URL, shows them: do not open it to read them.

## Do not

- Do not dump `queries/2` or `callbacks/2` for a large page into your context:
  start from `summary/2` and filter (`Enum.filter/2`, `Enum.take/2`).
- Do not search for sessions older than about 10 minutes: they expire. Trigger
  the page again.
- Do not run EXPLAIN or touch processes from here: `Report` is read-only.
  Suggest the toolbar's Ecto tab (EXPLAIN button) to the user instead.
