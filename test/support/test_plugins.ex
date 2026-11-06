defmodule PhoenixDevToolbar.TestPlugins.Echo do
  @moduledoc false
  use PhoenixDevToolbar.Plugin, id: :echo

  alias PhoenixDevToolbar.Event

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: [[:pdt_test, :echo]]

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, {_measurements, %{skip: true}}, _context), do: :skip

  def collect(_event, {_measurements, metadata}, context),
    do: {:record, Event.new(:echo, :echo, %{value: metadata[:value], source: context.source})}
end
