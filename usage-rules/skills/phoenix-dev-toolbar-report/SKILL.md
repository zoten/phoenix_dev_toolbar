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
  `page_n_plus_one`, `page_queries`, `page_callbacks` (`sort: "slowest"`) and
  `page_errors` for the details. Same keys as `Report`. No VM access needed.
- With Tidewave: run the code below through `project_eval`.
- With only a browser tool: skip the Elixir below and read the standalone
  panel, `http://localhost:4000/__pdt/panel?path=/posts`, through its
  `data-pdt-*` attributes (see the package's usage rules).
- Otherwise: a remote shell (`iex --sname probe --remsh app@<host>`), which needs
  the server started with a node name (`iex --sname app -S mix phx.server`), or
  ask the user to run it in the IEx session that started the server.
- Never `mix run` or a fresh `iex -S mix`: another VM, nothing captured.

Check first: for the Elixir paths, `PhoenixDevToolbar.enabled?()` must be `true`. For MCP, a `ping` or a `list_pages` call that works is the check.

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
  `:async` for task queries, such as `assign_async` or `start_async`).
  These items are compact (no SQL,
  params or assigns): use `queries/2` and `callbacks/2`, or `summary(page,
  verbose: true)` (`page_summary` with `verbose: true`), for the detail.

`latest/1` can pick up a page the user opened in another tab. When unsure, use
`Report.sessions(path: "/posts", limit: 5)` (over MCP, `list_pages` with
`path: "/posts"`) and keep the session whose
`started_at` follows your trigger.

## 4. Change the code, trigger again, compare

Re-run steps 2 and 3 (code reloading applies the change on the next request)
and compare the same fields. Report the delta: "/posts: 23 queries (21 ms) ->
3 queries (4 ms), N+1 on `comments` gone".

## Going deeper

- `Report.n_plus_one(page)`: repeated SQL with its `origin` (the calling line).
  `origin` (also on queries, briefs, inferred callbacks and errors) is the first
  app stack frame, else the function a task was started with, else
  `task in View.callback` or `task in View`. `nil` usually means the repo lacks
  `stacktrace: true` in `config/dev.exs`, but a `start_async` query can still
  have a nil N+1 origin.
- `Report.callbacks(page)`: each LiveView callback with its duration and the
  `queries` and `query_us` it caused; find the expensive `mount` or
  `handle_event`.
- `Report.queries(page)`: every query with SQL, params, rows and timings.
- `Report.errors(page)`: request exceptions, failed callbacks and renders,
  failed queries. A crash's call arguments (`stack_args`) are absent unless the
  developer enabled `stack_args: [agents: true]`: do not ask for them.

## Do not

- Do not dump `queries/2` or `callbacks/2` for a large page into your context:
  start from `summary/2` and filter (`Enum.filter/2`, `Enum.take/2`).
- Do not search for sessions older than about 10 minutes: they expire. Trigger
  the page again.
- Do not run EXPLAIN or touch processes from here: `Report` is read-only.
  Suggest the toolbar's Ecto tab (EXPLAIN button) to the user instead.
