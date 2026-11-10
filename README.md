# PhoenixDevToolbar

[![CI](https://github.com/zoten/phoenix_dev_toolbar/actions/workflows/ci.yml/badge.svg)](https://github.com/zoten/phoenix_dev_toolbar/actions/workflows/ci.yml)

A dev-only, BEAM-native debug toolbar for Phoenix LiveView applications, in the
spirit of `django-debug-toolbar`: Ecto queries, LiveView assigns and lifecycle
timings, process diagnostics and a plugin API, shown as an overlay on the page
you are working on.

> Status: early development. 0.0.x releases may break between versions. See the [roadmap](https://github.com/zoten/phoenix_dev_toolbar/blob/main/docs/2026-11-05-roadmap.md).

<!-- TODO(owner): add a screenshot or GIF recorded from `mix dev` -->

> **Disclaimer:** this project is currently fully AI-coded and has not been reviewed
> by a human yet. Use it at your own risk.

## What you get

- **Summary bar**: one badge per tab (query count, N+1 flag, LiveView callbacks, dropped events), always visible on the page.
- **Request tab**: the routed request, its route, status and duration, and exceptions with the stacktrace.
- **Ecto tab**: every query with its params (values under sensitive key names are redacted, positional params are not: see `redact:`), timings (total, queue, query, decode) and origin, attributed to the request, the LiveView callback or the `Task` that ran it.
- **N+1 detection**: the same query from the same origin repeated 5 times in one callback is flagged (the threshold is configurable).
- **EXPLAIN**: one click on a SELECT, run in a transaction that is rolled back, never `EXPLAIN ANALYZE`.
- **JSON export** of the page's queries, short or with EXPLAIN plans.
- **LiveView tab**: lifecycle timings (`mount`, `handle_params`, `handle_event`, `render`), assigns with a diff per event, an event log that includes client `phx:` events, and the component tree.
- **Process tab**: memory, message queue, reductions and garbage collection of the page's LiveView, with links, monitors and nested LiveViews.
- **System tab**: open any process by pid or name, read its info and stacktrace, walk its supervision and application trees, and list the top processes by memory, reductions or queue. Opt-in actions (`actions:` option): state read, kill, suspend, message peek and a message trace (OTP 27+).
- **Cluster and Eval plugins** (experimental, opt-in): connected nodes, and read queries or code evaluated on the node.
- **Plugin API**: your own tabs and badges, with a [guide](https://hexdocs.pm/phoenix_dev_toolbar/writing-a-plugin.html).
- **Docks and resize**: bottom, top, left or right, draggable size, collapse to a thin bar or hide to a pill. It follows LiveView live navigation.

## Requirements

- Elixir 1.17 or later, Phoenix 1.8 or later, LiveView 1.1 or later.
- OTP 26 or later is tested in CI. Some process reads need OTP 26.2, and the message trace needs OTP 27.
- `ecto_sql` is optional: without it the Ecto tab stays empty and nothing else changes.
- A browser with WebSocket support: the panel has no long-poll fallback.

## Installation

```elixir
# mix.exs
{:phoenix_dev_toolbar, "~> 0.0.1", only: :dev}

# config/dev.exs
config :phoenix_dev_toolbar, repos: [MyApp.Repo]  # optional: defaults to your apps' :ecto_repos
config :my_app, MyApp.Repo, stacktrace: true  # optional: shows where each query comes from

# lib/my_app_web/endpoint.ex, next to Phoenix.LiveReloader
if code_reloading? do
  plug PhoenixDevToolbar.Plug
end
```

That's all: no router, layout or `app.js` changes. See
[ADR 01](https://github.com/zoten/phoenix_dev_toolbar/blob/main/adr/01-zero-prod-footprint-and-installation.md) for why it never reaches production.

## Configuration

Everything is optional and goes in `config/dev.exs`:

```elixir
config :phoenix_dev_toolbar,
  # Panels: the built-ins plus your own (guides/writing-a-plugin.md)
  plugins: [:defaults, {MyApp.Toolbar.Jobs, queues: [:default]}],
  # The Ecto tab flags an N+1 at 5 repeats in one callback: change it, or false
  # plugins: [:defaults, {PhoenixDevToolbar.Plugins.Ecto, n_plus_one: 10}],
  # The Process tab reads the page's LiveView every second (60 points kept) and
  # its links and monitors every 5 seconds, only while the tab is open:
  # plugins: [:defaults, {PhoenixDevToolbar.Plugins.Process, sample_ms: 1000, samples: 60, relations_ms: 5000}],
  # The System tab inspects any process (a pid, a registered name, a link from the
  # Process tab), with the same options:
  # plugins: [:defaults, {PhoenixDevToolbar.Plugins.System, sample_ms: 1000}],
  # Opt-in: connected nodes (Cluster) and read queries or code on the node (Eval,
  # read only and for this machine's browser unless allow: :eval / clients: :any,
  # see SECURITY.md):
  # plugins: [:defaults, PhoenixDevToolbar.Plugins.Cluster, {PhoenixDevToolbar.Plugins.Eval, allow: :eval}],
  # Kill, suspend, message peek, state read and trace are off (false, the default).
  # :loopback allows them for a browser on this machine reaching the server directly;
  # :any for Docker, the LAN or a local proxy or tunnel (anyone reaching the server
  # can use them)
  # actions: :loopback,
  # The panel answers IP addresses, localhost, and your endpoint's url host; list
  # other names you use for the dev server (a DNS rebinding guard)
  # allowed_hosts: ["myapp.test"],
  # Behind a proxy or tunnel that rewrites the Host header, the page's origins
  # (scheme, host and port, matched exactly) the panel socket accepts
  # allowed_origins: ["https://abc.tunnel.example"],
  # The MCP endpoint for coding agents at <path>/mcp (loopback only); false turns it off
  # mcp: true,
  # The toolbar makes room so the page scrolls clear of it; false lets it overlap
  # (the dock menu's toggle overrides this per browser)
  reserve_space: true,
  # Values of keys containing these words are shown as [REDACTED]; added to the
  # defaults (password, token, secret), which always apply
  redact: ["api_key"],
  # Memory bounds (ADR 03), these are the defaults. A session is one request
  # or one LiveView process: a LiveView page has two.
  limits: [
    max_events: 500,           # per plugin and session, oldest trimmed first
    max_session_events: 2000,  # per session, all plugins together
    max_sessions: 50,          # sessions kept, oldest closed ones evicted first
    events_per_second: 200,    # per session, the rest are counted as dropped
    # ttl_ms: 600_000,         # a session is dropped this long after its last event
    # sweep_ms: 30_000,        # how often expired sessions are looked for
    # down_grace_ms: 60_000,   # a LiveView that went down keeps its events this long
  ]
```

Each built-in plugin documents its options in its module docs: `PhoenixDevToolbar.Plugins.Ecto`,
`.Process`, `.System`, `.Cluster` and `.Eval`.

Invalid `limits` values are logged at boot and keep their default.

### When it is on

The toolbar enables itself only when the app runs under Mix with `MIX_ENV=dev`. Any other
env (a release, `prod`, `test`, a custom one like `local` or `staging`) leaves it off
unless you set `config :phoenix_dev_toolbar, enabled: true`. For a custom Mix env the dependency
is not compiled there when declared `only: :dev`, so list that env too
(`only: [:dev, :local]`) AND set `enabled: true`.

### Turning it off for one run

Keep the dependency and the plug, and drive `enabled` from an environment variable:

```elixir
# config/dev.exs
config :phoenix_dev_toolbar, enabled: System.get_env("DEV_TOOLBAR") != "0"
```

Then `DEV_TOOLBAR=0 mix phx.server` boots without the toolbar: no telemetry handlers,
no supervised processes, and the plug passes requests through untouched. The value is
read at boot, so restart to switch it.

## From IEx or an agent

`PhoenixDevToolbar.Report` reads what the toolbar captured without a browser, from IEx in your dev server or from an agent that evaluates code in the running app (such as Tidewave):

```elixir
alias PhoenixDevToolbar.Report

Report.latest(path: "/posts") |> Report.summary()   # queries, N+1, slow callbacks, errors
Report.sessions(path: ~r{^/posts}, limit: 5)
Report.latest(path: "/posts") |> Report.n_plus_one()
```

It sees what the panel sees, for as long as the toolbar keeps it (10 minutes by default). A separate `mix run` starts another VM with nothing captured.

Agents that drive a browser can open the panel in a tab of its own: `/__pdt/panel?path=/posts` shows the newest `/posts` page, `/__pdt/panel` the newest page. Its rows carry `data-pdt-*` attributes with raw values (microseconds, counts, sids), listed in the `PhoenixDevToolbar.Plug` docs.

### MCP server

The toolbar is also an MCP server, at `http://localhost:4000/__pdt/mcp` while your dev server runs. Its read-only tools (`list_pages`, `page_summary`, `page_queries`, `page_callbacks`, `page_n_plus_one`, `page_errors`) return the same data as `Report`. It is on whenever the toolbar is, answers only clients on this machine (loopback, no proxy), and `config :phoenix_dev_toolbar, mcp: false` turns it off.

Check it with a ping, which answers a JSON result:

```sh
curl -s -X POST -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"ping"}' http://localhost:4000/__pdt/mcp
```

The tools answer "No page captured" until the page was loaded (browser, or `curl` with `Accept: text/html`) in the last 10 minutes.

Point your agent at it (change the port, or `/__pdt` if you set the plug's `:path`):

```sh
# Claude Code: writes .mcp.json, shared with the project
claude mcp add --transport http --scope project phoenix-dev-toolbar http://localhost:4000/__pdt/mcp

# Codex (recent releases): writes ~/.codex/config.toml
codex mcp add phoenix-dev-toolbar --url http://localhost:4000/__pdt/mcp
```

Or by hand:

```jsonc
// .mcp.json (Claude Code and other clients that read it)
{"mcpServers": {"phoenix-dev-toolbar": {"type": "http", "url": "http://localhost:4000/__pdt/mcp"}}}

// .cursor/mcp.json (Cursor)
{"mcpServers": {"phoenix-dev-toolbar": {"url": "http://localhost:4000/__pdt/mcp"}}}

// .vscode/mcp.json (VS Code)
{"servers": {"phoenix-dev-toolbar": {"type": "http", "url": "http://localhost:4000/__pdt/mcp"}}}
```

```toml
# ~/.codex/config.toml, or .codex/config.toml in a trusted project (Codex)
[mcp_servers.phoenix-dev-toolbar]
url = "http://localhost:4000/__pdt/mcp"
```

Claude Code asks once to approve a server from the project's `.mcp.json`; `/mcp` shows whether it is connected. Older Codex releases also need `experimental_use_rmcp_client = true` for HTTP servers. Start the dev server before the agent, or reconnect the server from the agent once it runs. A dev server inside a container sees your agent as a non-loopback client and refuses it.

The package ships [usage rules](https://hexdocs.pm/usage_rules) and a skill that teaches coding agents this check-before-and-after routine. With `usage_rules` in your project:

```elixir
# mix.exs, project/0
usage_rules: [
  file: "AGENTS.md",
  usage_rules: [:phoenix_dev_toolbar],
  skills: [package_skills: [:phoenix_dev_toolbar]]
]
```

then `mix usage_rules.sync`.

## How it compares

- [Phoenix LiveDashboard](https://github.com/phoenixframework/phoenix_live_dashboard): node-wide metrics and processes on its own page, not tied to the page you are viewing. Better for metrics over time.
- [LiveDebugger](https://github.com/software-mansion/live-debugger): deeper LiveView state debugging. This toolbar's LiveView tab overlaps with it; use LiveDebugger when LiveView state is the whole problem.
- [Tidewave](https://tidewave.ai): gives coding agents runtime access to your app. A different job: this toolbar is for the developer looking at a page.
- [phoenix_profiler](https://hex.pm/packages/phoenix_profiler): an existing profiler and debug toolbar for Phoenix.
- What this one adds: everything is attributed to the page in front of you (its request, its LiveView processes and their tasks), with N+1 detection per callback and one-click EXPLAIN.

## Troubleshooting

**The toolbar does not appear.**
- It is on only under `MIX_ENV=dev` (see "When it is on").
- `plug PhoenixDevToolbar.Plug` must be inside the endpoint's `if code_reloading?` block.
- It injects only into top-level HTML documents answered with status 200 that have a `</body>`. Compressed responses (a `content-encoding` other than `identity`), JSON, fragments and iframe or fetch requests get nothing.

**A strict Content-Security-Policy hides it.** Give the plug your CSP nonce through `conn.assigns`; the injected script and the toolbar frame style both use it:

```elixir
conn = Plug.Conn.assign(conn, :csp_nonce, nonce)      # in a plug before PhoenixDevToolbar.Plug
plug PhoenixDevToolbar.Plug, nonce_assign: :csp_nonce # the default key; change it if yours differs
```

A `frame-src` or `child-src` that excludes your own origin still blocks the panel frame.

**The panel answers 403.** The host name you use is not allowed (a DNS rebinding guard). The panel answers IP addresses, `localhost` and your endpoint's url host; add other names with `allowed_hosts: ["myapp.test"]`.

**The panel does not connect behind a proxy or tunnel.** If the proxy rewrites the `Host` header, the browser's origin no longer matches what the server sees and the socket is refused (the log names both). List the page's origin, exactly as the browser shows it: `allowed_origins: ["https://abc.tunnel.example"]` (no paths or wildcards; an entry that cannot match is logged at boot and ignored). Remove it when the tunnel is gone: a free tunnel name may later belong to someone else. A proxy that keeps the `Host` header needs the name in `allowed_hosts` instead.

**Docker or LAN access.** Add the host name to `allowed_hosts`. Process actions are off by default; `actions: :loopback` allows them for a browser on this machine and `actions: :any` for Docker or the LAN (anyone who can reach the server can then use them). Eval is limited to this machine unless `clients: :any`.

**The Ecto tab is empty.** The toolbar watches the repos in your apps' `:ecto_repos`; if there are none it logs one warning. Set `repos: [MyApp.Repo]` in `config/dev.exs`.

## Security

The toolbar is for development. It is off outside `MIX_ENV=dev`, adds nothing to a production build when installed with `only: :dev`, and the panel refuses other origins and unknown host names. Process actions and the Eval plugin are opt-in and limited to a browser on this machine by default. Report vulnerabilities privately: see [SECURITY.md](https://github.com/zoten/phoenix_dev_toolbar/blob/main/SECURITY.md).

## Contributing

The ADR index ([adr/README.md](https://github.com/zoten/phoenix_dev_toolbar/blob/main/adr/README.md)) is the place to start. [AGENTS.md](https://github.com/zoten/phoenix_dev_toolbar/blob/main/AGENTS.md) is written for AI coding agents. Run `mix precommit` before pushing (its JS tests need Node 22 or later).
`mix precommit` rebuilds the assets (the first run downloads the esbuild binary, so it needs network) and fails if `priv/static` differs from the committed bundles.
CI also compiles `fixtures/host_app` in prod and dev, which `mix precommit` does not (run it there with `mix compile --warnings-as-errors`).
CI also tests the minimum supported versions (Elixir 1.17, OTP 26, LiveView 1.1): `agent-tools/ci-min.sh` runs that row locally in Docker.
Try your changes in a real browser with `mix dev`, a demo app at http://localhost:4000.

## License

MIT, see [LICENSE](https://github.com/zoten/phoenix_dev_toolbar/blob/main/LICENSE).
