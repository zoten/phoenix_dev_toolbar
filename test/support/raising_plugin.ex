defmodule PhoenixDevToolbar.TestPlugins.Raising do
  @moduledoc false
  use PhoenixDevToolbar.Plugin, id: :raising
  # Raises on purpose: fixture for collect/3 crash isolation.
  @dialyzer {:nowarn_function, collect: 3}

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: [[:pdt_test, :echo]]

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: raise("boom")
end
