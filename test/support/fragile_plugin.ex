defmodule PhoenixDevToolbar.TestPlugins.Fragile do
  @moduledoc false
  # Raises on demand, wherever its code runs: collect/3 (host process) for
  # value "collect", summary_add/2 for "summary", badges/1 for "badges", its
  # panel for "panel" (handle_events) and "render". "bad_title" makes badges/1
  # return a malformed badge.
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
  def summary_init(_config), do: %{count: 0, last: nil}

  @impl true
  def summary_add(_summary, %Event{data: %{value: "summary"}}), do: raise("summary boom")
  def summary_add(summary, event), do: %{count: summary.count + 1, last: event.data.value}

  @impl true
  def badges(%{last: "badges"}), do: raise("badges boom")

  def badges(%{last: "bad_title", count: count}),
    do: [%{id: "fragile", text: "#{count} fragile", level: :info, title: %{not: "a string"}}]

  def badges(%{count: count}), do: [%{id: "fragile", text: "#{count} fragile", level: :info}]
end
