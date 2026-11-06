defmodule PhoenixDevToolbar.TestPlugins.ThrowingId do
  @moduledoc false
  # A hand written plugin whose id/0 throws: Config must skip it, not crash boot.
  @behaviour PhoenixDevToolbar.Plugin

  @impl PhoenixDevToolbar.Plugin
  def id, do: throw(:nope)

  @impl PhoenixDevToolbar.Plugin
  def name, do: "Throwing"

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: []

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: :skip
end
