defmodule PhoenixDevToolbar.TestPlugins.SameId do
  @moduledoc false
  # Claims the Echo plugin's id: Config keeps the first of the two.
  use PhoenixDevToolbar.Plugin, id: :echo

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: []

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: :skip
end
