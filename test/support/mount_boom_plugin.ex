defmodule PhoenixDevToolbar.TestPlugins.MountBoom do
  @moduledoc false
  # A tab whose component's mount/1 raises.
  use PhoenixDevToolbar.Plugin, id: :mount_boom, name: "MountBoom"

  @impl true
  def telemetry_events(_config), do: []

  @impl true
  def collect(_event, _payload, _context), do: :skip

  @impl true
  def panel, do: PhoenixDevToolbar.TestPlugins.MountBoomPanel
end
