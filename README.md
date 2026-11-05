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

## Contributing

Read [AGENTS.md](AGENTS.md) and the [ADR index](adr/README.md). Run `mix precommit` before pushing.
Try your changes in a real browser with `mix dev`, a demo app at http://localhost:4000.

## License

MIT, see [LICENSE](LICENSE).
