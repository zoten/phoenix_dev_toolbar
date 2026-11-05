# ADR 05: Plugin Behaviour

**Status:** Accepted  
**Area:** plugins  
**Related:** [ADR 02](./02-telemetry-collection-and-correlation.md) (collection rules), [ADR 03](./03-event-storage.md) (storage)

## Context

The community will want panels for Oban, Ash, auth state, Absinthe and more. If
built-ins use private paths, the plugin API rots. A plugin also runs code inside
host processes (its collector), so the contract must make the cheap path obvious.

## Decision

Every panel, built-ins included, implements `PhoenixDevToolbar.Plugin`:

```elixir
defmodule PhoenixDevToolbar.Plugin do
  alias PhoenixDevToolbar.{Context, Event}

  @type state :: term()
  @type summary :: %{badge: String.t() | nil, level: :info | :warn | :error}

  @callback id() :: atom()
  @callback name() :: String.t()
  @callback init(opts :: keyword()) :: {:ok, state()}
  @callback telemetry_events() :: [:telemetry.event_name()]

  @doc "Runs inside the emitting host process: cheap, pure, never raises."
  @callback collect_metrics(:telemetry.event_name(), {measurements :: map(), metadata :: map()}, Context.t()) ::
              {:record, Event.t()} | :skip

  @doc "Runs in the panel process."
  @callback summary([Event.t()], state()) :: summary()
  @callback render_panel(assigns :: map()) :: Phoenix.LiveView.Rendered.t()
  @callback handle_panel_event(event :: String.t(), params :: map(), state()) :: {:ok, state()}

  @optional_callbacks init: 1, summary: 2, handle_panel_event: 3
end
```

- `use PhoenixDevToolbar.Plugin` imports `Phoenix.Component`, sets `@behaviour` and
  default implementations for optional callbacks.
- `Context` carries the sid, the attribution source (`:self | :caller`) and a monotonic
  timestamp; `Event` is a struct (`plugin`, `kind`, `at`, `duration`, `data`) with `data`
  already truncated by the plugin through `PhoenixDevToolbar.Truncate`.
- The collector attaches one handler per event name and fans out to the plugins that
  declared it. A plugin that raises in `collect_metrics/3` is quarantined (disabled for
  the node until code reload) and the panel shows the error.
- Registration:

```elixir
config :phoenix_dev_toolbar,
  plugins: [:defaults, {MyApp.Toolbar.ObanPanel, queues: [:default]}]
```

  `:defaults` expands to the built-ins (Request, Ecto, LiveView, Process); listing a
  built-in with options overrides it, `{:exclude, Mod}` removes one.

## Consequences

- Built-ins are the reference implementation and the API's test suite.
- `render_panel/1` runs inside our iframe, so plugin markup cannot break the host.

## Open limits

- Plugins cannot add pull-based data sources yet (only telemetry); a `poll/2` callback
  is a Phase 3 candidate, driven by the Process panel needs.
- The behaviour is unstable until 1.0: changes go in the CHANGELOG.
