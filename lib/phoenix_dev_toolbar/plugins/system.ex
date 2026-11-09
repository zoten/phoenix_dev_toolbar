defmodule PhoenixDevToolbar.Plugins.System do
  @moduledoc false
  # Built-in System tab (ADR 11): any local process, by pid, registered name or
  # a link from another tab. It attaches no telemetry and has no summary: a tab
  # only, reading nothing until someone inspects a process.
  # Options: PhoenixDevToolbar.ProcessOptions (`sample_ms:`, `samples:`, `relations_ms:`).

  use PhoenixDevToolbar.Plugin, id: :system, name: "System"

  alias PhoenixDevToolbar.ProcessOptions

  @impl PhoenixDevToolbar.Plugin
  defdelegate init(opts), to: ProcessOptions

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: []

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: :skip

  @impl PhoenixDevToolbar.Plugin
  def panel, do: PhoenixDevToolbar.Panels.System
end
