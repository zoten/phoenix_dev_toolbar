defmodule PhoenixDevToolbar.TestPlugins.Tabbed do
  @moduledoc false
  # A third party style plugin with a tab and a badge, built only on the public
  # API (Plugin, Panel, Event, Context): what the guide promises.
  use PhoenixDevToolbar.Plugin, id: :tabbed, name: "Tabbed"

  alias PhoenixDevToolbar.Event

  @impl PhoenixDevToolbar.Plugin
  def init(opts), do: {:ok, %{prefix: Keyword.get(opts, :prefix, "value")}}

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: [[:pdt_test, :echo]]

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, {_measurements, metadata}, context) do
    data = %{text: "#{context.config.prefix} #{metadata[:value]}"}
    {:record, Event.new(:tabbed, :echo, data)}
  end

  @impl PhoenixDevToolbar.Plugin
  def panel, do: PhoenixDevToolbar.TestPlugins.TabbedPanel

  @impl PhoenixDevToolbar.Plugin
  def summary_init(_config), do: 0

  @impl PhoenixDevToolbar.Plugin
  def summary_add(count, %Event{}), do: count + 1

  @impl PhoenixDevToolbar.Plugin
  def badges(count), do: [%{id: "tabbed", text: "#{count} echoes", level: :info}]
end
