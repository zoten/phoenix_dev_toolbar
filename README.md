# PhoenixDevToolbar

A dev-only, BEAM-native debug toolbar for Phoenix LiveView applications, in the
spirit of `django-debug-toolbar`: Ecto queries, LiveView assigns and lifecycle
timings, process diagnostics and a plugin API, shown as an overlay on the page
you are working on.

> Status: early development, not yet published. See the [roadmap](docs/2026-11-05-roadmap.md).

## Installation (planned)

```elixir
# mix.exs
{:phoenix_dev_toolbar, "~> 0.1", only: :dev}

# config/dev.exs
config :phoenix_dev_toolbar, repos: [MyApp.Repo]
config :my_app, MyApp.Repo, stacktrace: true  # optional: shows where each query comes from

# lib/my_app_web/endpoint.ex, next to Phoenix.LiveReloader
if code_reloading? do
  plug PhoenixDevToolbar.Plug
end
```

That's all: no router, layout or `app.js` changes. See
[ADR 01](adr/01-zero-prod-footprint-and-installation.md) for why it never reaches production.

## Configuration

Everything is optional and goes in `config/dev.exs`:

```elixir
config :phoenix_dev_toolbar,
  # Panels: the built-ins plus your own (see PhoenixDevToolbar.Plugin)
  plugins: [:defaults, {MyApp.Toolbar.Jobs, queues: [:default]}],
  # Values of keys containing these words are shown as [REDACTED]
  redact: ["password", "token", "secret"],
  # Memory bounds (ADR 03), these are the defaults
  limits: [
    max_events: 500,           # per plugin and page, oldest trimmed first
    max_session_events: 2000,  # per page, all plugins together
    max_sessions: 50,          # pages kept, oldest closed ones evicted first
    events_per_second: 200     # per page, the rest are counted as dropped
  ]
```

## Contributing

Read [AGENTS.md](AGENTS.md) and the [ADR index](adr/README.md). Run `mix precommit` before pushing (its JS tests need Node 22 or later).
Try your changes in a real browser with `mix dev`, a demo app at http://localhost:4000.

## License

MIT, see [LICENSE](LICENSE).
