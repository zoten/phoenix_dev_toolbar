defmodule PhoenixDevToolbar.TestPlugins.HalfSummary do
  @moduledoc false
  # Defines summary_init/1 without summary_add/2 and badges/1: Config skips it.
  use PhoenixDevToolbar.Plugin, id: :half_summary

  @impl true
  def telemetry_events(_config), do: []

  @impl true
  def collect(_event, _payload, _context), do: :skip

  @impl true
  def summary_init(_config), do: 0
end
