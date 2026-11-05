# ADR 01: Zero Production Footprint and Installation

**Status:** Accepted  
**Area:** architecture  
**Related:** [ADR 04](./04-ui-delivery.md) (what the plug injects), [ADR 06](./06-dev-harness-and-testing.md) (prod compile check)

## Context

A debug toolbar that leaks into production is a security and performance
incident (exposed queries, assigns, process info). Installation must also be
short enough that people actually try it.

## Decision

Three layers keep production clean:

1. The dependency is declared `only: :dev`, so the code is not even compiled in prod.
2. Every host-facing entry point lives behind Phoenix's own dev guards:
   `if code_reloading?` in the endpoint and `if Application.compile_env(:my_app, :dev_routes)`
   in the router, the same pattern as `Phoenix.LiveReloader` and `live_dashboard`.
3. At runtime every entry point (plug, router macro, telemetry attach, supervisor
   children) checks `PhoenixDevToolbar.enabled?/0` (`config :phoenix_dev_toolbar, enabled: false`
   turns everything into a no-op, for example in `:test` of the host app).

Installation:

```elixir
# mix.exs
{:phoenix_dev_toolbar, "~> 0.1", only: :dev}

# config/dev.exs
config :phoenix_dev_toolbar, repos: [MyApp.Repo]
config :my_app, MyApp.Repo, stacktrace: true  # optional: query origins

# lib/my_app_web/endpoint.ex, next to Phoenix.LiveReloader
if code_reloading? do
  plug PhoenixDevToolbar.Plug
end

# lib/my_app_web/router.ex
if Application.compile_env(:my_app, :dev_routes) do
  import PhoenixDevToolbar.Router

  scope "/" do
    pipe_through :browser
    dev_toolbar "/__pdt"
  end
end
```

No change to the host `root.html.heex` or `app.js` is required: the plug injects
the loader (ADR 04).

## Consequences

- Hosts with `only: :dev` cannot reference our modules from code compiled in
  other envs; docs always show the guarded form.
- CI compiles a fixture host app in `MIX_ENV=prod` without the dependency to
  prove the guarded install compiles cleanly.

## Open limits

- An Igniter installer (`mix igniter.install phoenix_dev_toolbar`) is planned for Phase 3.
- Hosts using a custom endpoint without `code_reloading?` must guard manually.
