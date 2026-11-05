defmodule PhoenixDevToolbar.Collector do
  @moduledoc false
  # Telemetry entry point (ADR 02). One handler per event name fans out to the
  # plugins that declared it. Handlers run inside host processes:
  #
  #   * untracked process: one pdict read (plus `$callers` lookups) and return
  #   * never raise: `:telemetry` detaches a raising handler for good
  #   * a raising plugin is quarantined and logged once, others keep working

  require Logger

  alias PhoenixDevToolbar.Attribution
  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Context
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.Tracker

  @mount_start [:phoenix, :live_view, :mount, :start]

  @doc "Attaches handlers for `plugins`, replacing any previous attachment."
  @spec attach([module()]) :: :ok
  def attach(plugins) do
    detach()
    Enum.each(plugins, &release/1)

    plugins
    |> Enum.flat_map(fn plugin -> Enum.map(plugin.telemetry_events(), &{&1, plugin}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    # Session tracking needs the mount event even when no plugin asks for it.
    |> Map.put_new(@mount_start, [])
    |> Enum.each(fn {event, event_plugins} ->
      :ok = :telemetry.attach({Collector, event}, event, &Collector.handle_event/4, event_plugins)
    end)
  end

  @doc "Detaches every toolbar handler."
  @spec detach() :: :ok
  def detach do
    for %{id: {Collector, _event} = id} <- :telemetry.list_handlers([]), do: :telemetry.detach(id)
    :ok
  end

  @doc false
  @spec handle_event(:telemetry.event_name(), map(), map(), [module()]) :: :ok
  def handle_event(event, measurements, metadata, plugins) do
    maybe_track(event, metadata)

    case Attribution.current() do
      nil ->
        :ok

      {sid, source} ->
        collect(plugins, event, {measurements, metadata}, %Context{sid: sid, source: source})
    end
  catch
    # Every class: `:telemetry` detaches a handler on throws and exits too.
    kind, reason ->
      log_once(
        {Collector, :logged, kind, error_type(reason)},
        "collector",
        Exception.format(kind, reason, __STACKTRACE__)
      )
  end

  @doc false
  @spec quarantined?(module()) :: boolean()
  def quarantined?(plugin), do: :persistent_term.get(quarantine_key(plugin), false)

  defp maybe_track(@mount_start, %{socket: socket} = metadata),
    do: Tracker.live_view_mount(socket, metadata[:uri])

  defp maybe_track(_event, _metadata), do: :ok

  defp collect(plugins, event, payload, %Context{} = context) do
    for plugin <- plugins,
        not quarantined?(plugin),
        do: collect_one(plugin, event, payload, context)

    :ok
  end

  # Only the plugin's own code can quarantine it: Store and Notify failures are
  # ours and are handled by the handler level catch.
  defp collect_one(plugin, event, payload, %Context{sid: sid} = context) do
    case run_plugin(plugin, event, payload, context) do
      {:record, %Event{} = recorded} -> maybe_notify(Store.insert(sid, recorded), sid)
      _skip_or_quarantined -> :ok
    end
  end

  defp run_plugin(plugin, event, payload, context) do
    case plugin.collect_metrics(event, payload, context) do
      {:record, %Event{}} = record ->
        record

      :skip ->
        :skip

      other ->
        raise ArgumentError, "expected {:record, %Event{}} or :skip, got: #{inspect(other)}"
    end
  catch
    kind, reason ->
      quarantine(plugin, Exception.format(kind, reason, __STACKTRACE__))
      :quarantined
  end

  defp error_type(%{__struct__: module}), do: module
  defp error_type(_reason), do: :other

  defp maybe_notify(:ok, sid), do: Notify.event(sid)
  defp maybe_notify(_result, _sid), do: :ok

  defp quarantine(plugin, formatted) do
    log_once(quarantine_key(plugin), "plugin #{inspect(plugin)} (now disabled)", formatted)
  end

  defp release(plugin) do
    _ = :persistent_term.erase(quarantine_key(plugin))
    :ok
  end

  defp quarantine_key(plugin), do: {Collector, :quarantined, plugin}

  # `:persistent_term.put/2` is expensive, but runs once per key.
  defp log_once(key, what, formatted) do
    case :persistent_term.get(key, false) do
      true ->
        :ok

      false ->
        :persistent_term.put(key, true)
        Logger.error("[phoenix_dev_toolbar] #{what} raised:\n" <> formatted)
    end
  end
end
