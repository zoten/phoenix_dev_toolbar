`phoenix_dev_toolbar` is a dev-only debug toolbar for Phoenix LiveView apps. It
records each page view (the request and its LiveView processes) with its Ecto
queries, LiveView callbacks, renders and errors, and shows them in a panel.

## Installation stays dev-only

- The dependency is declared `only: :dev`.
- The only integration point is `plug PhoenixDevToolbar.Plug` inside the
  endpoint's `if code_reloading? do` block. Never add a router macro, an
  `import`, a layout change or an `app.js` change for it: none is needed, and
  any of them breaks the production build.
- Configuration goes in `config/dev.exs` (`config :phoenix_dev_toolbar, ...`).
- For query origins, set `stacktrace: true` on the repo in `config/dev.exs`.

## Reading what it captured

`PhoenixDevToolbar.Report` reads the captured data without a browser:

```elixir
alias PhoenixDevToolbar.Report

Report.latest(path: "/posts") |> Report.summary()
Report.latest(path: "/posts") |> Report.n_plus_one()
Report.sessions(path: ~r{^/posts}, limit: 5)
```

- It only works inside the running dev server's VM: IEx started with the
  server, a remote shell, or a tool that evaluates code in the running app (for
  example Tidewave's `project_eval`). `mix run` or a new `iex -S mix` starts
  another VM where nothing was captured.
- Use it to check claims about a page ("N+1 fixed", "fewer queries", "no
  errors") with numbers before and after a change.
- Start with `summary/2`: its slowest queries, callbacks and errors are compact
  (no SQL or assigns). Read `queries/2` or `callbacks/2`, or pass `verbose: true`,
  when you need the detail.
- Data expires after 10 minutes by default: trigger the page again rather than
  looking for old sessions.
- It is read-only. EXPLAIN and process actions are in the browser panel only.

## Reading it over MCP

When the project's MCP config has the `phoenix-dev-toolbar` server
(`http://localhost:4000/__pdt/mcp`), prefer its tools to evaluating code:

- `list_pages` (filter with `path` or `path_prefix`; `since` takes a sid or
  ISO 8601 time: note the sid you measured, edit, reload, then list with
  `since` to get only pages that started after it), then `page_summary` with
  the page's `sid` or its `path` (compact; `verbose: true` for full items).
  Without either, tools read the newest page.
- To check a change: `page_summary`, note its `sid`, edit, reload the page,
  then `compare_pages` with `before: sid` (the newest capture of the same path
  after it, or pass `after` or `path`): deltas, N+1 and errors fixed or new
  (`before.panel_url` and `after.panel_url` link both pages).
- `page_report` returns a page as Markdown (tables, SQL in fenced blocks): use it
  to paste a finding into a bug report or answer.
- `page_assigns_shape` weighs the assigns of the page's LiveView (type, length,
  words, `stream?`, no values): look for big lists that should be streams. It
  reads the LiveView live, so the page must be open in a browser. Read
  `live_view_sid`, `note` and `warning` in the result: they say which LiveView
  was read when it is not the one you asked for (older capture, live navigation).
- The `audit_page` prompt (argument `path`) runs the whole audit of one page:
  summary, N+1, slowest queries, errors, assigns shape, then a report.
- `recent_errors` after a change: crashes in `handle_info` or in other tabs that
  the page lookups miss (`since` takes the sid you measured: errors after that page started, never that page's own; or a time; `limit`).
- `page_queries`, `page_callbacks` (`sort: "slowest"`, `limit`, filters `callback`, `event`; `page_queries` also `span`, `seq_from`, `seq_to`, and compact rows unless `verbose: true`),
  `page_n_plus_one`, `page_errors` for the details. Queries carry `callback`,
  `event`, `origin` (the Repo call site), `caller` (the LiveView, controller
  or `on_mount` frame above it) and `noise` (framework queries such as
  `Phoenix.Ecto.CheckRepoStatus`, left out of `page_summary` counts). N+1
  groups carry `ran_in` (the callbacks) and `callers` (frames with counts).
  Inferred `handle_info` callbacks have `duration_us: null`: sum with a default.
- Tools or fields missing from your tool list after a `phoenix_dev_toolbar`
  upgrade: the client connected before it. Ask the user to reconnect
  (`/mcp` in Claude Code).
- A "No page captured" error means the page was not loaded in the last 10
  minutes, or not as an HTML document: load it again, then retry.
- Results carry `panel_url`: give it to the user to see the page in the panel.
- When a call fails: connection refused means the server is not running or the
  port is wrong (a server bound to a LAN address does not answer on localhost:
  use that address); 403 "MCP is limited to this machine" names the refused
  address, which the user can allow with `mcp: [clients: [...]]`; 403 "MCP
  refused a proxied request" needs `mcp: [clients: :any]`; 403 "Host not
  allowed" means the host must be added to `allowed_hosts:`; a 404 HTML page
  means the plug's `:path` is not `/__pdt` or the toolbar is disabled; 404 "MCP
  is off" means `mcp: false`.
- "No captured page at <path>": `path` is an exact match on the path the page
  started at (a live patch keeps its LiveView's mount path); call `list_pages`.

## Reading it in a browser

When you drive a browser instead of evaluating code in the app:

- Load the page, then open `/__pdt/panel?path=/posts` (the newest `/posts`
  page), `/__pdt/panel` (the newest page) or `/__pdt/panel?sid=<sid>`. `/__pdt`
  is the plug's default `:path`.
- Read the `data-pdt-*` attributes, not the formatted text: for example
  `[data-pdt-row="query"]` rows carry `data-pdt-duration-us`, `data-pdt-source`
  and `data-pdt-n-plus-one`; `#pdt-panel[data-pdt-root]` is the page's sid.
  Every tab is in the DOM, hidden ones too. The full list is in the plug docs
  (`PhoenixDevToolbar.Plug`, "Standalone panel").
- `?path=` and the newest page answer this machine only (`#pdt-empty` with
  `data-pdt-lookup="gated"` otherwise); `?sid=` works from anywhere the panel
  does. The `#pdt-empty` text says why there is no page.
- Reload the panel after triggering the page again: it shows the page it found
  when it loaded.
