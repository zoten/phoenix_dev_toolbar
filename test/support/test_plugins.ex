defmodule PhoenixDevToolbar.TestPlugins.Echo do
  @moduledoc false
  @behaviour PhoenixDevToolbar.Plugin

  alias PhoenixDevToolbar.Event

  @impl true
  def id, do: :echo

  @impl true
  def telemetry_events, do: [[:pdt_test, :echo]]

  @impl true
  def collect_metrics(_event, {_measurements, %{skip: true}}, _context), do: :skip

  def collect_metrics(_event, {_measurements, metadata}, context),
    do: {:record, Event.new(:echo, :echo, %{value: metadata[:value], source: context.source})}
end
