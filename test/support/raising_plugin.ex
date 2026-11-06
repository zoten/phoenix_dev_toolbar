defmodule PhoenixDevToolbar.TestPlugins.Raising do
  @moduledoc false
  use PhoenixDevToolbar.Plugin, id: :raising

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: [[:pdt_test, :echo]]

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: raise("boom")
end
