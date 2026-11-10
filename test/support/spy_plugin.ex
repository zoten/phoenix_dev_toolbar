defmodule PhoenixDevToolbar.TestPlugins.Spy do
  @moduledoc false
  # Sends every event it is asked to collect to the `:pid` option, records nothing.
  use PhoenixDevToolbar.Plugin, id: :spy, name: "Spy"

  @impl PhoenixDevToolbar.Plugin
  def init(opts), do: {:ok, %{pid: Keyword.fetch!(opts, :pid)}}

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: [[:pdt_test, :echo]]

  @impl PhoenixDevToolbar.Plugin
  def collect(event, _payload, context) do
    send(context.config.pid, {:spy_collected, event, context.source})
    :skip
  end
end
