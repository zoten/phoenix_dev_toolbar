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
  alias PhoenixDevToolbar.Config
  alias PhoenixDevToolbar.Context
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.Tracker

  @mount_start [:phoenix, :live_view, :mount, :start]

  @plugins_key {Collector, :plugins}

  @doc """
  Attaches handlers for `plugins` (`Config.plugins/0` entries, or bare modules),
  replacing any previous attachment. Runs each plugin's `init/1` here: a plugin
  whose `init/1` or `telemetry_events/1` fails is logged and left out.
  """
  @spec attach([Config.entry() | module()]) :: :ok
  def attach(plugins) do
    detach()

    attached = Enum.flat_map(plugins, &attachable/1)
    configs = Enum.map(attached, fn {plugin, config, _events} -> {plugin, config} end)
    :persistent_term.put(@plugins_key, configs)

    attached
    |> Enum.flat_map(fn {plugin, config, events} -> Enum.map(events, &{&1, {plugin, config}}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    # Session tracking needs the mount event even when no plugin asks for it.
    |> Map.put_new(@mount_start, [])
    |> Enum.each(fn {event, event_plugins} ->
      :ok = :telemetry.attach({Collector, event}, event, &Collector.handle_event/4, event_plugins)
    end)
  end

  @doc "The attached plugins with their config, in configuration order."
  @spec plugins() :: [{module(), term()}]
  def plugins, do: :persistent_term.get(@plugins_key, [])

  defp attachable(entry) do
    {plugin, opts} = normalize(entry)
    release(plugin)

    case start(plugin, opts) do
      {:ok, config, events} -> [{plugin, config, events}]
      :skip -> []
    end
  end

  defp normalize({plugin, opts}) when is_atom(plugin) and is_list(opts), do: {plugin, opts}
  defp normalize(plugin) when is_atom(plugin), do: {plugin, []}

  defp start(plugin, opts) do
    with {:ok, config} <- init(plugin, opts),
         events when is_list(events) <- plugin.telemetry_events(config) do
      {:ok, config, events}
    else
      {:error, reason} -> skip(plugin, "init/1 returned an error: #{reason}")
      other -> skip(plugin, "unexpected return: #{inspect(other, limit: 5)}")
    end
  catch
    kind, reason -> skip(plugin, Exception.format(kind, reason, __STACKTRACE__))
  end

  defp init(plugin, opts) do
    # function_exported?/3 does not load the module: a plugin not loaded yet
    # would silently skip its init/1.
    case Code.ensure_loaded?(plugin) and function_exported?(plugin, :init, 1) do
      true -> plugin.init(opts)
      false -> {:ok, opts}
    end
  end

  defp skip(plugin, why) do
    Logger.error("[phoenix_dev_toolbar] plugin #{inspect(plugin)} is disabled: #{why}")
    :skip
  end

  @doc "Detaches every toolbar handler."
  @spec detach() :: :ok
  def detach do
    for %{id: {Collector, _event} = id} <- :telemetry.list_handlers([]), do: :telemetry.detach(id)
    :ok
  end

  @doc false
  @spec handle_event(:telemetry.event_name(), map(), map(), [{module(), term()}]) :: :ok
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
    for {plugin, config} <- plugins,
        not quarantined?(plugin),
        do: collect_one(plugin, event, payload, %{context | config: config})

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
    case plugin.collect(event, payload, context) do
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
