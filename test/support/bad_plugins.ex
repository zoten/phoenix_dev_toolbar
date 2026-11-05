defmodule PhoenixDevToolbar.TestPlugins.BadEvents do
  @moduledoc false
  # telemetry_events/1 returns what the config says: `{BadEvents, events: ...}`.
  use PhoenixDevToolbar.Plugin, id: :bad_events

  @impl true
  def telemetry_events(config), do: Keyword.fetch!(config, :events)

  @impl true
  def collect(_event, _payload, _context),
    do: {:record, PhoenixDevToolbar.Event.new(:bad_events, :echo, %{})}
end
