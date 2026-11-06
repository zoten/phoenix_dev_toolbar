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
config :phoenix_dev_toolbar, repos: [MyApp.Repo]
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
  # Values of keys containing these words are shown as [REDACTED]
  redact: ["password", "token", "secret"],
  # Memory bounds (ADR 03), these are the defaults. A session is one request
  # or one LiveView process: a LiveView page has two.
  limits: [
    max_events: 500,           # per plugin and session, oldest trimmed first
    max_session_events: 2000,  # per session, all plugins together
    max_sessions: 50,          # sessions kept, oldest closed ones evicted first
    events_per_second: 200     # per session, the rest are counted as dropped
  ]
```

The options shown for the built-in Ecto and Process plugins are all they accept.

Invalid `limits` values are logged at boot and keep their default.

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
