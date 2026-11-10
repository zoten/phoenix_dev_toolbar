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
