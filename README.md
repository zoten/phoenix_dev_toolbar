# PhoenixDevToolbar

[![CI](https://github.com/zoten/phoenix_dev_toolbar/actions/workflows/ci.yml/badge.svg)](https://github.com/zoten/phoenix_dev_toolbar/actions/workflows/ci.yml)

A dev-only, BEAM-native debug toolbar for Phoenix LiveView applications, in the
spirit of `django-debug-toolbar`: Ecto queries, LiveView assigns and lifecycle
timings, process diagnostics and a plugin API, shown as an overlay on the page
you are working on.

> Status: early development, not on Hex yet. See the [roadmap](https://github.com/zoten/phoenix_dev_toolbar/blob/main/docs/2026-11-05-roadmap.md).

> **Disclaimer:** this project is currently fully AI-coded and has not been reviewed
> by a human yet. Use it at your own risk.

## Installation

```elixir
# mix.exs: from GitHub until the first Hex release
{:phoenix_dev_toolbar, github: "zoten/phoenix_dev_toolbar", only: :dev}

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
unless you set `config :phoenix_dev_toolbar, enabled: true`.

### Turning it off for one run

Keep the dependency and the plug, and drive `enabled` from an environment variable:

```elixir
# config/dev.exs
config :phoenix_dev_toolbar, enabled: System.get_env("DEV_TOOLBAR") != "0"
```

Then `DEV_TOOLBAR=0 mix phx.server` boots without the toolbar: no telemetry handlers,
no supervised processes, and the plug passes requests through untouched. The value is
read at boot, so restart to switch it.

## Contributing

Read [AGENTS.md](https://github.com/zoten/phoenix_dev_toolbar/blob/main/AGENTS.md) and the [ADR index](https://github.com/zoten/phoenix_dev_toolbar/blob/main/adr/README.md). Run `mix precommit` before pushing (its JS tests need Node 22 or later).
Try your changes in a real browser with `mix dev`, a demo app at http://localhost:4000.

## License

MIT, see [LICENSE](https://github.com/zoten/phoenix_dev_toolbar/blob/main/LICENSE).
