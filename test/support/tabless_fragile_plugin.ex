defmodule PhoenixDevToolbar.TestPlugins.TablessFragile do
  @moduledoc false
  # No tab; collect/3 raises for value "tabless".
  use PhoenixDevToolbar.Plugin, id: :tabless, name: "Tabless"

  alias PhoenixDevToolbar.Event

  @impl true
  def telemetry_events(_config), do: [[:pdt_test, :echo]]

  @impl true
  def collect(_event, {_measurements, %{value: "tabless"}}, _context), do: raise("tabless boom")
  def collect(_event, _payload, _context), do: {:record, Event.new(:tabless, :echo, %{})}
end
