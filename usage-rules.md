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
- Start with `summary/2`; read `queries/2` or `callbacks/2` only when you need
  the full list.
- Data expires after 10 minutes by default: trigger the page again rather than
  looking for old sessions.
- It is read-only. EXPLAIN and process actions are in the browser panel only.

## Reading it over MCP

When the project's MCP config has the `phoenix-dev-toolbar` server
(`http://localhost:4000/__pdt/mcp`), prefer its tools to evaluating code:

- `list_pages` (filter with `path` or `path_prefix`), then `page_summary` with
  the page's `sid` or its `path`. Without either, tools read the newest page.
- `page_queries`, `page_callbacks` (`sort: "slowest"`, `limit`),
  `page_n_plus_one`, `page_errors` for the details.
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
