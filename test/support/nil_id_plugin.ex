defmodule PhoenixDevToolbar.TestPlugins.NilId do
  @moduledoc false
  # A hand written plugin whose id/0 is nil: Config must skip it.
  @behaviour PhoenixDevToolbar.Plugin

  @impl PhoenixDevToolbar.Plugin
  def id, do: nil

  @impl PhoenixDevToolbar.Plugin
  def name, do: "Nil"

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: []

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: :skip
end
