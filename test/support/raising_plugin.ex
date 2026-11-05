defmodule PhoenixDevToolbar.TestPlugins.Raising do
  @moduledoc false
  use PhoenixDevToolbar.Plugin, id: :raising

  @impl true
  def telemetry_events(_config), do: [[:pdt_test, :echo]]

  @impl true
  def collect(_event, _payload, _context), do: raise("boom")
end
