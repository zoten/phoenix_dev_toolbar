defmodule PhoenixDevToolbar.TestPlugins.ThrowingId do
  @moduledoc false
  # A hand written plugin whose id/0 throws: Config must skip it, not crash boot.
  @behaviour PhoenixDevToolbar.Plugin

  @impl true
  def id, do: throw(:nope)

  @impl true
  def name, do: "Throwing"

  @impl true
  def telemetry_events(_config), do: []

  @impl true
  def collect(_event, _payload, _context), do: :skip
end
