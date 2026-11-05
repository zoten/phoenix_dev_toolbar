defmodule PhoenixDevToolbar.TestPlugins.BadPanel do
  @moduledoc false
  # panel/0 returns a module that is not a PhoenixDevToolbar.Panel: Config skips it.
  use PhoenixDevToolbar.Plugin, id: :bad_panel

  @impl true
  def telemetry_events(_config), do: []

  @impl true
  def collect(_event, _payload, _context), do: :skip

  @impl true
  def panel, do: DemoWeb.HelloPlug
end
