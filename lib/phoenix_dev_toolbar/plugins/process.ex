defmodule PhoenixDevToolbar.Plugins.Process do
  @moduledoc false
  # Built-in Process tab (ADR 09): the page's LiveView process, read while
  # someone looks. It attaches no telemetry and has no summary: a tab only.
  # Options: PhoenixDevToolbar.ProcessOptions (`sample_ms:`, `samples:`, `relations_ms:`).

  use PhoenixDevToolbar.Plugin, id: :process, name: "Process"

  alias PhoenixDevToolbar.ProcessOptions

  @impl PhoenixDevToolbar.Plugin
  defdelegate init(opts), to: ProcessOptions

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: []

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: :skip

  @impl PhoenixDevToolbar.Plugin
  def panel, do: PhoenixDevToolbar.Panels.Process
end
