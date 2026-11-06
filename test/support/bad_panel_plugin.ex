defmodule PhoenixDevToolbar.TestPlugins.BadPanel do
  @moduledoc false
  # panel/0 returns a module that is not a PhoenixDevToolbar.Panel: Config skips it.
  use PhoenixDevToolbar.Plugin, id: :bad_panel

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: []

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: :skip

  @impl PhoenixDevToolbar.Plugin
  def panel, do: DemoWeb.HelloPlug
end
