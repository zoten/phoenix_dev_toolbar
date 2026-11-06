defmodule PhoenixDevToolbar.TestPlugins.NilId do
  @moduledoc false
  # A hand written plugin whose id/0 is nil: Config must skip it.
  @behaviour PhoenixDevToolbar.Plugin

  @impl true
  def id, do: nil

  @impl true
  def name, do: "Nil"

  @impl true
  def telemetry_events(_config), do: []

  @impl true
  def collect(_event, _payload, _context), do: :skip
end
