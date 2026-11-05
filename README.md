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

# endpoint.ex
if code_reloading? do
  plug PhoenixDevToolbar.Plug
end

# router.ex
if Application.compile_env(:my_app, :dev_routes) do
  import PhoenixDevToolbar.Router

  scope "/" do
    pipe_through :browser
    dev_toolbar "/__pdt"
  end
end
```

See [ADR 01](adr/01-zero-prod-footprint-and-installation.md) for why it never reaches production.

## Contributing

Read [AGENTS.md](AGENTS.md) and the [ADR index](adr/README.md). Run `mix precommit` before pushing.

## License

MIT, see [LICENSE](LICENSE).
