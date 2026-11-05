defmodule PhoenixDevToolbar.Shell do
  @moduledoc false
  # What the panel knows about the attached plugins (ADR 05): their tabs, their
  # summaries folded event by event, and which tab an event goes to. Pure: the
  # PanelLive glue renders it and delivers the events.

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Shell

  defstruct plugins: [], by_id: %{}, summaries: %{}

  @type tab :: %{
          id: String.t(),
          plugin: module(),
          panel: module(),
          name: String.t(),
          config: term()
        }
  @type t :: %Shell{
          plugins: [{module(), term()}],
          by_id: %{atom() => module()},
          summaries: %{atom() => term()}
        }

  @doc "The shell of the attached plugins (`Collector.plugins/0`), summaries empty."
  @spec new([{module(), term()}]) :: t()
  def new(plugins) do
    shell = %Shell{
      plugins: plugins,
      by_id: Map.new(plugins, fn {plugin, _} -> {plugin.id(), plugin} end)
    }

    reset(shell, [])
  end

  @doc "The plugins' tabs, in configuration order."
  @spec tabs(t()) :: [tab()]
  def tabs(%Shell{plugins: plugins}) do
    for {plugin, config} <- plugins, function_exported?(plugin, :panel, 0) do
      %{
        id: Atom.to_string(plugin.id()),
        plugin: plugin,
        panel: plugin.panel(),
        name: plugin.name(),
        config: config
      }
    end
  end

  @doc "Summaries of a new page, folded from all its events."
  @spec reset(t(), [Event.t()]) :: t()
  def reset(%Shell{plugins: plugins} = shell, events) do
    summaries =
      for {plugin, config} <- plugins, summary?(plugin), into: %{} do
        {plugin.id(), plugin.summary_init(config)}
      end

    fold(%{shell | summaries: summaries}, events)
  end

  @doc "Folds new events into their plugins' summaries."
  @spec fold(t(), [Event.t()]) :: t()
  def fold(%Shell{} = shell, events) do
    summaries =
      Enum.reduce(events, shell.summaries, fn %Event{plugin: id} = event, acc ->
        case acc do
          %{^id => summary} -> %{acc | id => shell.by_id[id].summary_add(summary, event)}
          _no_summary -> acc
        end
      end)

    %{shell | summaries: summaries}
  end

  @doc "The summary bar badges of every plugin, in configuration order."
  @spec badges(t()) :: [PhoenixDevToolbar.Plugin.badge()]
  def badges(%Shell{plugins: plugins, summaries: summaries}) do
    for {plugin, _config} <- plugins,
        {:ok, summary} <- [Map.fetch(summaries, plugin.id())],
        badge <- plugin.badges(summary),
        do: badge
  end

  @doc "Events grouped by the tab they go to, oldest first; others are dropped."
  @spec route(t(), [Event.t()]) :: %{String.t() => [Event.t()]}
  def route(%Shell{} = shell, events) do
    tabs = shell |> tabs() |> MapSet.new(& &1.id)

    events
    |> Enum.group_by(&Atom.to_string(&1.plugin))
    |> Map.filter(fn {id, _events} -> MapSet.member?(tabs, id) end)
  end

  defp summary?(plugin), do: function_exported?(plugin, :summary_init, 1)
end
