defmodule PhoenixDevToolbar.TestPlugins.Strict do
  @moduledoc false
  use PhoenixDevToolbar.Plugin, id: :strict, name: "Strict"

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: [[:pdt_test, :strict]]

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: :skip

  @impl PhoenixDevToolbar.Plugin
  def panel, do: PhoenixDevToolbar.TestPlugins.StrictPanel
end
