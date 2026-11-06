defmodule PhoenixDevToolbar.TestPlugins.MountBoom do
  @moduledoc false
  # A tab whose component's mount/1 raises.
  use PhoenixDevToolbar.Plugin, id: :mount_boom, name: "MountBoom"

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: []

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: :skip

  @impl PhoenixDevToolbar.Plugin
  def panel, do: PhoenixDevToolbar.TestPlugins.MountBoomPanel
end
