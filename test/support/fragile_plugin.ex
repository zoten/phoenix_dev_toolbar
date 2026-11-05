defmodule PhoenixDevToolbar.TestPlugins.Fragile do
  @moduledoc false
  # Raises on demand, wherever its code runs: collect/3 (host process) for
  # value "collect", summary_add/2 for "summary", its panel for "panel".
  use PhoenixDevToolbar.Plugin, id: :fragile, name: "Fragile"

  alias PhoenixDevToolbar.Event

  @impl true
  def telemetry_events(_config), do: [[:pdt_test, :echo]]

  @impl true
  def collect(_event, {_measurements, %{value: "collect"}}, _context), do: raise("collect boom")

  def collect(_event, {_measurements, metadata}, _context),
    do: {:record, Event.new(:fragile, :echo, %{value: metadata[:value]})}

  @impl true
  def panel, do: PhoenixDevToolbar.TestPlugins.FragilePanel

  @impl true
  def summary_init(_config), do: 0

  @impl true
  def summary_add(_count, %Event{data: %{value: "summary"}}), do: raise("summary boom")
  def summary_add(count, _event), do: count + 1

  @impl true
  def badges(count), do: [%{id: "fragile", text: "#{count} fragile", level: :info}]
end
