defmodule PhoenixDevToolbar.TestPlugins.BadgeOnly do
  @moduledoc false
  # A summary and badges, no tab.
  use PhoenixDevToolbar.Plugin, id: :badge_only

  alias PhoenixDevToolbar.Event

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: [[:pdt_test, :echo]]

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: {:record, Event.new(:badge_only, :echo, %{})}

  @impl PhoenixDevToolbar.Plugin
  def summary_init(_config), do: 0

  @impl PhoenixDevToolbar.Plugin
  def summary_add(count, _event), do: count + 1

  @impl PhoenixDevToolbar.Plugin
  def badges(count), do: [%{id: "badge_only", text: "#{count} seen", level: :warn}]
end
