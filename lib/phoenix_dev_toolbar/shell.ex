defmodule PhoenixDevToolbar.Shell do
  @moduledoc false
  # What the panel knows about the attached plugins (ADR 05): their tabs, their
  # summaries folded event by event, and which tab an event goes to. Pure: the
  # PanelLive glue renders it and delivers the events.

  require Logger

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Shell
  alias PhoenixDevToolbar.Truncate

  defstruct plugins: [], by_id: %{}, summaries: %{}, badges: %{}, broken: %{}

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
          summaries: %{atom() => term()},
          badges: %{atom() => [PhoenixDevToolbar.Plugin.badge()]},
          broken: %{String.t() => String.t()}
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

  @doc """
  Summaries of a new page, folded from all its events. Plugin code runs here
  (summary_init/1, summary_add/2, badges/1): a plugin that raises is marked
  broken for this panel (`broken/1`) and skipped, the others keep working.
  """
  @spec reset(t(), [Event.t()]) :: t()
  def reset(%Shell{plugins: plugins} = shell, events) do
    shell = %{shell | summaries: %{}, badges: %{}}

    plugins
    |> Enum.filter(fn {plugin, _config} -> summary?(plugin) end)
    |> Enum.reduce(shell, fn {plugin, config}, acc ->
      guard(acc, plugin, fn -> put_summary(acc, plugin.id(), plugin.summary_init(config)) end)
    end)
    |> fold(events)
  end

  @doc "Folds new events into their plugins' summaries."
  @spec fold(t(), [Event.t()]) :: t()
  def fold(%Shell{} = shell, events) do
    events
    |> Enum.group_by(& &1.plugin)
    |> Enum.reduce(shell, fn {id, plugin_events}, acc ->
      case acc.summaries do
        %{^id => summary} ->
          plugin = acc.by_id[id]

          guard(acc, plugin, fn ->
            put_summary(acc, id, Enum.reduce(plugin_events, summary, &plugin.summary_add(&2, &1)))
          end)

        _no_summary ->
          acc
      end
    end)
  end

  @doc "The summary bar badges of every plugin, in configuration order."
  @spec badges(t()) :: [PhoenixDevToolbar.Plugin.badge()]
  def badges(%Shell{plugins: plugins, badges: badges}) do
    for {plugin, _config} <- plugins, badge <- Map.get(badges, plugin.id(), []), do: badge
  end

  @doc "Plugins whose panel code raised in this panel, by tab id, with the error banner."
  @spec broken(t()) :: %{String.t() => String.t()}
  def broken(%Shell{broken: broken}), do: broken

  @doc "Forgets a plugin's error (the Re-enable button); the next reset folds it again."
  @spec mend(t(), String.t()) :: t()
  def mend(%Shell{} = shell, tab_id), do: %{shell | broken: Map.delete(shell.broken, tab_id)}

  # Badges are computed when the summary changes, not at render: a raising
  # badges/1 breaks the plugin, never the panel's render.
  defp put_summary(shell, id, summary) do
    badges = shell.by_id[id].badges(summary) |> List.wrap() |> Enum.filter(&badge?/1)

    %{
      shell
      | summaries: Map.put(shell.summaries, id, summary),
        badges: Map.put(shell.badges, id, badges)
    }
  end

  defp badge?(%{id: id, text: text, level: level} = badge) when is_binary(id) and is_binary(text),
    do: level in [:ok, :info, :warn, :error] and title?(badge[:title])

  defp badge?(_badge), do: false

  defp title?(title), do: is_nil(title) or is_binary(title)

  defp guard(shell, plugin, fun) do
    tab_id = Atom.to_string(plugin.id())

    case shell.broken do
      %{^tab_id => _banner} -> shell
      _ok -> fun.()
    end
  catch
    kind, reason ->
      Logger.error(
        "[phoenix_dev_toolbar] plugin #{inspect(plugin)} raised in the panel:\n" <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      id = plugin.id()

      %{
        shell
        | broken: Map.put(shell.broken, Atom.to_string(id), Truncate.banner(kind, reason)),
          summaries: Map.delete(shell.summaries, id),
          badges: Map.delete(shell.badges, id)
      }
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
