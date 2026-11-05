defmodule PhoenixDevToolbar.TestPlugins.SameId do
  @moduledoc false
  # Claims the Echo plugin's id: Config keeps the first of the two.
  use PhoenixDevToolbar.Plugin, id: :echo

  @impl true
  def telemetry_events(_config), do: []

  @impl true
  def collect(_event, _payload, _context), do: :skip
end
