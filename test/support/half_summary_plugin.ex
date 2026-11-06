defmodule PhoenixDevToolbar.TestPlugins.HalfSummary do
  @moduledoc false
  # Defines summary_init/1 without summary_add/2 and badges/1: Config skips it.
  use PhoenixDevToolbar.Plugin, id: :half_summary

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: []

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: :skip

  @impl PhoenixDevToolbar.Plugin
  def summary_init(_config), do: 0
end
