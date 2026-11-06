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
  alias PhoenixDevToolbar.Truncate

  @mount_start [:phoenix, :live_view, :mount, :start]

  # Callback boundaries (ADR 02): a tracked process starts a new span at each
  # start (before the plugins see it) and each stop or exception (after).
  @span_callbacks [
    [:phoenix, :live_view, :mount],
    [:phoenix, :live_view, :handle_params],
    [:phoenix, :live_view, :handle_event],
    [:phoenix, :live_view, :render],
    [:phoenix, :live_component, :update],
    [:phoenix, :live_component, :handle_event]
  ]
  @span_edges Map.new(
                for prefix <- @span_callbacks,
                    {stage, edge} <- [start: :before, stop: :after, exception: :after],
                    do: {prefix ++ [stage], edge}
              )

  @plugins_key {Collector, :plugins}
  @configs_key {Collector, :configs}

  @doc """
  Attaches handlers for `plugins` (`Config.plugins/0` entries, or bare modules),
  replacing any previous attachment. Runs each plugin's `init/1` here: a plugin
  whose `init/1` or `telemetry_events/1` fails is logged and left out.
  """
  @spec attach([Config.entry() | module()]) :: :ok
  def attach(plugins) do
    detach()

    attached = Enum.flat_map(plugins, &attachable/1)
    configs = Enum.map(attached, fn {plugin, _id, config, _events} -> {plugin, config} end)
    :persistent_term.put(@plugins_key, configs)

    :persistent_term.put(
      @configs_key,
      Map.new(attached, fn {plugin, id, config, _events} -> {plugin, {id, config}} end)
    )

    # The handler config holds module names only: `:telemetry` copies it into
    # every emitting process, tracked or not. Configs are read from
    # persistent_term (no copy) once a process is known to be tracked.
    attached
    |> Enum.flat_map(fn {plugin, _id, _config, events} -> Enum.map(events, &{&1, plugin}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    # Session tracking needs the mount event, and spans the callback
    # boundaries, even when no plugin asks for them.
    |> then(fn by_event ->
      Enum.reduce(Map.keys(@span_edges), by_event, &Map.put_new(&2, &1, []))
    end)
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
      {:ok, id, config, events} -> [{plugin, id, config, events}]
      :skip -> []
    end
  end

  defp normalize({plugin, opts}) when is_atom(plugin) and is_list(opts), do: {plugin, opts}
  defp normalize(plugin) when is_atom(plugin), do: {plugin, []}
  defp normalize(other), do: {other, nil}

  # A bad event name would make :telemetry.attach/4 raise in the host's
  # application start: checked here, the plugin is skipped instead.
  defp start(plugin, opts) when not is_atom(plugin) or not is_list(opts),
    do: skip(plugin, "expected Module or {Module, opts}")

  defp start(plugin, opts) do
    with id when is_atom(id) and id not in [nil, true, false] <- plugin.id(),
         {:ok, config} <- init(plugin, opts),
         events when is_list(events) <- plugin.telemetry_events(config),
         true <- Enum.all?(events, &event_name?/1) do
      {:ok, id, config, Enum.uniq(events)}
    else
      {:error, reason} when is_binary(reason) ->
        skip(plugin, "init/1 returned an error: #{reason}")

      false ->
        skip(plugin, "telemetry_events/1 must return lists of atoms")

      other ->
        skip(plugin, "unexpected return: #{inspect(other, limit: 5)}")
    end
  catch
    kind, reason -> skip(plugin, Exception.format(kind, reason, __STACKTRACE__))
  end

  defp event_name?([_ | _] = name), do: Enum.all?(name, &is_atom/1)
  defp event_name?(_name), do: false

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
  @spec handle_event(:telemetry.event_name(), map(), map(), [module()]) :: :ok
  def handle_event(event, measurements, metadata, plugins) do
    maybe_track(event, metadata)

    case Attribution.current() do
      nil ->
        :ok

      {sid, :self, span} ->
        edge = Map.get(@span_edges, event)
        context = %Context{sid: sid, source: :self, span: span_before(edge, span)}
        collect(plugins, event, {measurements, metadata}, context)
        span_after(edge)

      {sid, :caller, span} ->
        context = %Context{sid: sid, source: :caller, span: span}
        collect(plugins, event, {measurements, metadata}, context)
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

  defp span_before(:before, _span), do: Attribution.next_span()
  defp span_before(_edge, span), do: span

  defp span_after(:after) do
    _ = Attribution.next_span()
    :ok
  end

  defp span_after(_edge), do: :ok

  @doc false
  @spec quarantined?(module()) :: boolean()
  def quarantined?(plugin), do: :persistent_term.get(quarantine_key(plugin), nil) != nil

  @doc "Why `plugin` was disabled (a bounded error banner), or nil."
  @spec quarantine_reason(module()) :: String.t() | nil
  def quarantine_reason(plugin), do: :persistent_term.get(quarantine_key(plugin), nil)

  @doc """
  Re-enables a quarantined plugin (the panel's Re-enable button). Erasing a
  persistent_term is expensive: only on an explicit user action.
  """
  @spec release(module()) :: :ok
  def release(plugin) do
    _ = :persistent_term.erase(quarantine_key(plugin))
    :ok
  end

  defp maybe_track(@mount_start, %{socket: socket} = metadata),
    do: Tracker.live_view_mount(socket, metadata[:uri])

  defp maybe_track(_event, _metadata), do: :ok

  defp collect(plugins, event, payload, %Context{} = context) do
    configs = :persistent_term.get(@configs_key, %{})

    for plugin <- plugins,
        not quarantined?(plugin),
        {:ok, {id, config}} <- [Map.fetch(configs, plugin)],
        do: collect_one(plugin, id, event, payload, %{context | config: config})

    :ok
  end

  # Only the plugin's own code can quarantine it: Store and Notify failures are
  # ours and are handled by the handler level catch. Events are stamped with
  # the plugin's own id: a plugin cannot record into another one's tab or cap.
  defp collect_one(plugin, id, event, payload, %Context{sid: sid} = context) do
    case run_plugin(plugin, event, payload, context) do
      {:record, %Event{} = recorded} ->
        maybe_notify(Store.insert(sid, %{recorded | plugin: id, span: context.span}), sid)

      _skip_or_quarantined ->
        :ok
    end
  end

  defp run_plugin(plugin, event, payload, context) do
    case plugin.collect(event, payload, context) do
      {:record, %Event{}} = record ->
        record

      :skip ->
        :skip

      other ->
        raise ArgumentError,
              "expected {:record, %Event{}} or :skip, got: #{inspect(other, limit: 5)}"
    end
  catch
    kind, reason ->
      quarantine(plugin, kind, reason, __STACKTRACE__, context.sid)
      :quarantined
  end

  defp error_type(%{__struct__: module}), do: module
  defp error_type(_reason), do: :other

  defp maybe_notify(:ok, sid), do: Notify.event(sid)
  defp maybe_notify(_result, _sid), do: :ok

  # Stores the bounded banner the panel shows; logs the full error once.
  # `:persistent_term.put/2` is expensive, but runs once per quarantine.
  # The page that triggered it is notified, so its open panel shows the
  # disabled tab right away (Notify is a non blocking Registry dispatch).
  defp quarantine(plugin, kind, reason, stacktrace, sid) do
    key = quarantine_key(plugin)

    case :persistent_term.get(key, nil) do
      nil ->
        :persistent_term.put(key, Truncate.banner(kind, reason))
        Notify.event(sid)

        Logger.error(
          "[phoenix_dev_toolbar] plugin #{inspect(plugin)} (now disabled) raised:\n" <>
            Exception.format(kind, reason, stacktrace)
        )

      _banner ->
        :ok
    end
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
