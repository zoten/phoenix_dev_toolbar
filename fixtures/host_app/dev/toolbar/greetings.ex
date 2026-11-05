defmodule HostApp.Toolbar.Greetings do
  # A third party plugin as the guide says to install one (ADR 05): its module
  # lives in dev/, compiled only in :dev (elixirc_paths), because the toolbar
  # dependency does not exist in :prod. CI compiles both.
  @moduledoc false
  use PhoenixDevToolbar.Plugin, id: :greetings, name: "Greetings"

  alias PhoenixDevToolbar.Event

  @impl true
  def telemetry_events(_config), do: [[:host_app, :greeting]]

  @impl true
  def collect(_event, _payload, _context), do: {:record, Event.new(:greetings, :greeting, %{})}
end
