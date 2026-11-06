# ADR 01: Zero Production Footprint and Installation

**Status:** Implemented (2026-11-05)  
**Area:** architecture  
**Related:** [ADR 04](./04-ui-delivery.md) (what the plug injects and serves), [ADR 06](./06-dev-harness-and-testing.md) (prod compile check)

## Context

A debug toolbar that leaks into production is a security and performance
incident (exposed queries, assigns, process info). Installation must also be
short enough that people actually try it.

A dependency declared `only: :dev` does not exist when compiling for prod, so
any reference to its modules outside a block that the compiler skips breaks the
prod build. `plug Mod` inside `if code_reloading?` is safe (it only stores an
atom), but `import Mod` or a macro call inside `if Application.compile_env(...)`
is not: both branches of `if` are expanded at compile time. LiveDashboard's
router macro pattern works only because it is not a dev only dependency.

## Decision

Three layers keep production clean:

1. The dependency is declared `only: :dev`, so the code is not even compiled in prod.
2. The only host-facing entry point is `PhoenixDevToolbar.Plug`, inside the endpoint's
   `if code_reloading?` block, like `Phoenix.LiveReloader`. The plug also serves the
   panel and its assets (ADR 04), so the host router is untouched and nothing outside
   that block references the package.
3. At runtime every entry point (plug, telemetry attach, supervisor children) checks
   `PhoenixDevToolbar.enabled?/0` (`config :phoenix_dev_toolbar, enabled: false` turns
   everything into a no-op, for example in `:test` of the host app). When `enabled` is
   not configured and the application starts without `Mix` loaded (a release, so the
   dependency was installed without `only: :dev`), it disables itself and logs a
   warning; `enabled: true` forces it on. To skip the toolbar for a single dev run, the
   host reads `enabled` from an environment variable in `config/dev.exs` (README,
   "Turning it off for one run"); it is settled at boot, so switching needs a restart.

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
```

No change to the router, `root.html.heex` or `app.js` is required.

## Consequences

- One line of host code; uninstalling is deleting it and the dependency.
- The panel cannot use the host's router pipeline (auth, `on_mount` hooks), which is
  what we want: it is our own page.
- `fixtures/host_app` installs the package exactly as above. CI compiles it with
  `MIX_ENV=prod` (no dependency) and `MIX_ENV=dev` (with it), both with
  `--warnings-as-errors`.

## Open limits

- An Igniter installer (`mix igniter.install phoenix_dev_toolbar`) is planned, in a phase of its own.
- Hosts using a custom endpoint without `code_reloading?` must guard manually.
