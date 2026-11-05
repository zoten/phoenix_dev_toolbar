defmodule PhoenixDevToolbar.TestPlugins.Raising do
  @moduledoc false
  @behaviour PhoenixDevToolbar.Plugin

  @impl true
  def id, do: :raising

  @impl true
  def telemetry_events, do: [[:pdt_test, :echo]]

  @impl true
  def collect_metrics(_event, _payload, _context), do: raise("boom")
end
