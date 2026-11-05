defmodule PhoenixDevToolbar.Plugin do
  @moduledoc false
  # Collection half of the plugin behaviour. The rendering callbacks and the
  # public `use` macro land in Phase 3 (ADR 05).

  alias PhoenixDevToolbar.Context
  alias PhoenixDevToolbar.Event

  @callback id() :: atom()
  @callback telemetry_events() :: [:telemetry.event_name()]

  @doc "Runs inside the emitting host process: cheap, pure, never raises."
  @callback collect_metrics(:telemetry.event_name(), {map(), map()}, Context.t()) ::
              {:record, Event.t()} | :skip
end
