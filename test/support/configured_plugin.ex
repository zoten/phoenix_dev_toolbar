defmodule PhoenixDevToolbar.TestPlugins.Configured do
  @moduledoc false
  # A plugin with options: `init/1` validates `:label`, `collect/3` reads it back
  # from the context, and `fail: true` makes init/1 refuse.
  use PhoenixDevToolbar.Plugin, id: :configured, name: "Configured"

  alias PhoenixDevToolbar.Event

  @impl PhoenixDevToolbar.Plugin
  def init(opts) do
    case Keyword.fetch(opts, :label) do
      {:ok, label} when is_binary(label) -> {:ok, %{label: label}}
      _ -> {:error, "label must be a string"}
    end
  end

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: [[:pdt_test, :echo]]

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, context),
    do: {:record, Event.new(:configured, :echo, %{label: context.config.label})}
end
