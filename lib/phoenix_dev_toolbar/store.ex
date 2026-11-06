defmodule PhoenixDevToolbar.Store do
  @moduledoc false
  # Bounded in-memory event storage (ADR 03).
  #
  # The GenServer owns the ETS tables and does housekeeping (trimming, eviction,
  # TTL sweep, DOWN cleanup). It is never on the write path: host processes
  # write to the public tables directly and only `cast` to the server.
  #
  # Tables:
  #   :pdt_events      ordered_set  {{sid, seq}, %Event{}}
  #   :pdt_sessions    set          {sid, %Session{}, count, dropped, trimmed}
  #   :pdt_counts      set          {{sid, plugin}, count, trimmed}  (per plugin cap)
  #   :pdt_pids        set          {pid, sid, span}      ($callers attribution)
  #   :pdt_socket_ids  set          {socket_id, sid}      (dead render -> LiveView)
  #   :pdt_transports  set          {transport_pid, sid}  (latest sid per tab)
  #   :pdt_rate        set          {{sid, second}, n}    (flood guard)
  #   :pdt_panels      set          {panel_id, second}    (panel socket allowlist)

  use GenServer

  alias PhoenixDevToolbar.Config
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @events :pdt_events
  @sessions :pdt_sessions
  @pids :pdt_pids
  @socket_ids :pdt_socket_ids
  @transports :pdt_transports
  @rate :pdt_rate
  @counts :pdt_counts
  @panels :pdt_panels
  @tables [@events, @sessions, @pids, @socket_ids, @transports, @rate, @counts, @panels]

  # Panel LiveView ids the panel socket accepts (ADR 04): a day, 1000 at most.
  @panel_ttl_s 24 * 3600
  @max_panels 1000

  @limits_key {Store, :limits}
  @seq_key {Store, :seq}

  # After the first overflow, re-request a trim every @trim_every inserts.
  @trim_every 64

  @default_limits %{
    max_events: 500,
    max_session_events: 2000,
    max_sessions: 50,
    ttl_ms: :timer.minutes(10),
    sweep_ms: :timer.seconds(30),
    events_per_second: 200,
    down_grace_ms: :timer.seconds(60)
  }

  @type limits :: %{
          max_events: pos_integer(),
          max_session_events: pos_integer(),
          max_sessions: pos_integer(),
          ttl_ms: non_neg_integer(),
          sweep_ms: pos_integer(),
          events_per_second: pos_integer(),
          down_grace_ms: non_neg_integer()
        }

  @type insert_result :: :ok | :dropped | :no_session

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(Store, opts, name: Store)

  ## Sessions

  @doc "Registers a session. Runs in the caller: direct ETS insert plus a cast."
  @spec new_session(Session.t()) :: Session.t()
  def new_session(%Session{sid: sid} = session) do
    :ets.insert(@sessions, {sid, session, 0, 0, 0})
    maybe_index_transport(session)
    GenServer.cast(Store, {:session_created, session})
    session
  end

  @doc "Returns the session with its counters."
  @spec session(Session.sid()) :: {:ok, Session.t()} | :error
  def session(sid) do
    case :ets.lookup(@sessions, sid) do
      [{^sid, session, count, dropped, trimmed}] ->
        {:ok, %{session | count: count, dropped: dropped, trimmed: trimmed}}

      [] ->
        :error
    end
  end

  @doc "Lists all sessions, oldest first."
  @spec sessions() :: [Session.t()]
  def sessions do
    @sessions
    |> :ets.tab2list()
    |> Enum.map(fn {_sid, session, count, dropped, trimmed} ->
      %{session | count: count, dropped: dropped, trimmed: trimmed}
    end)
    |> Enum.sort_by(& &1.started_at)
  end

  @doc """
  Moves a session to a new owner process and transport (a LiveView rejoining
  with the same socket id), so the previous owner's DOWN does not expire it.
  """
  @spec claim(Session.sid(), pid(), pid() | nil) :: {:ok, Session.t()} | :error
  def claim(sid, owner, transport) when is_pid(owner) do
    case :ets.lookup(@sessions, sid) do
      [{^sid, session, _count, _dropped, _trimmed}] ->
        claimed = %{session | owner: owner, transport: transport}
        :ets.update_element(@sessions, sid, {2, claimed})
        maybe_index_transport(claimed)
        GenServer.cast(Store, {:monitor, sid, owner})
        {:ok, claimed}

      [] ->
        :error
    end
  end

  ## Indexes

  @doc "Attributes a process to a session (used for `$callers` lookups)."
  @spec track_pid(pid(), Session.sid(), non_neg_integer()) :: true
  def track_pid(pid, sid, span \\ 0) when is_pid(pid), do: :ets.insert(@pids, {pid, sid, span})

  @spec untrack_pid(pid()) :: true
  def untrack_pid(pid) when is_pid(pid), do: :ets.delete(@pids, pid)

  @spec sid_for_pid(pid()) :: Session.sid() | nil
  def sid_for_pid(pid) do
    case caller(pid) do
      {sid, _span} -> sid
      nil -> nil
    end
  end

  @doc """
  The sid of a tracked process and its current callback span, for its
  `$callers` children (ADR 02).
  """
  @spec caller(pid()) :: {Session.sid(), non_neg_integer()} | nil
  def caller(pid) do
    case :ets.lookup(@pids, pid) do
      [{^pid, sid, span}] -> {sid, span}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Records the current callback span of a tracked process (no row: a no-op)."
  @spec put_span(pid(), non_neg_integer()) :: boolean()
  def put_span(pid, span) when is_pid(pid) do
    :ets.update_element(@pids, pid, {3, span})
  rescue
    ArgumentError -> false
  end

  @doc """
  The processes tracked as `sid`: its LiveView and nested LiveViews (request
  processes leave the index when they respond). Scans the pid index, which only
  holds tracked processes; called by the panel, never by a handler.
  """
  @spec pids_for(Session.sid()) :: [pid()]
  def pids_for(sid), do: @pids |> :ets.match({:"$1", sid, :_}) |> List.flatten()

  @doc "Links a LiveView socket id (created during the dead render) to its sid."
  @spec link_socket_id(String.t(), Session.sid()) :: true
  def link_socket_id(socket_id, sid) when is_binary(socket_id),
    do: :ets.insert(@socket_ids, {socket_id, sid})

  @spec sid_for_socket_id(String.t()) :: Session.sid() | nil
  def sid_for_socket_id(socket_id), do: lookup(@socket_ids, socket_id)

  @doc "Returns the newest sid created on a transport (one per browser tab)."
  @spec latest_for_transport(pid() | nil) :: Session.sid() | nil
  def latest_for_transport(nil), do: nil
  def latest_for_transport(transport), do: lookup(@transports, transport)

  ## Events

  @doc """
  Stores an event for `sid`. Runs in the caller (a host process): only ETS
  operations, never a synchronous call.
  """
  @spec insert(Session.sid(), Event.t()) :: insert_result()
  def insert(sid, %Event{} = event), do: insert(sid, event, System.monotonic_time(:second))

  @doc false
  # `second` is the flood guard window, injectable for deterministic tests.
  @spec insert(Session.sid(), Event.t(), integer()) :: insert_result()
  def insert(sid, %Event{} = event, second) when is_binary(sid) do
    limits = limits()

    case within_rate?(sid, second, limits.events_per_second) do
      true -> do_insert(sid, event, limits)
      false -> count_dropped(sid)
    end
  rescue
    # Tables missing while the Store restarts: the event is lost, nothing else.
    ArgumentError -> :no_session
  end

  @doc "Per plugin counters of `sid`: events kept and events trimmed past the cap."
  @spec plugin_counts(Session.sid()) :: %{
          atom() => %{count: integer(), trimmed: non_neg_integer()}
        }
  def plugin_counts(sid) do
    for [plugin, count, trimmed] <- :ets.match(@counts, {{sid, :"$1"}, :"$2", :"$3"}),
        into: %{},
        do: {plugin, %{count: count, trimmed: trimmed}}
  rescue
    ArgumentError -> %{}
  end

  @doc """
  Lets the panel socket accept joins for the panel LiveView `id` (its dead
  render registers it). A day at most, 1000 panels at most: past the cap an
  arbitrary one gives way (O(1)), and that panel reloads if it rejoins.
  """
  @spec allow_panel(String.t()) :: :ok
  def allow_panel(id) when is_binary(id) do
    evict_panel(:ets.info(@panels, :size) >= @max_panels and not :ets.member(@panels, id))
    :ets.insert(@panels, {id, System.monotonic_time(:second)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp evict_panel(false), do: :ok

  defp evict_panel(true) do
    case :ets.first(@panels) do
      :"$end_of_table" -> :ok
      id -> :ets.delete(@panels, id)
    end
  end

  @doc "Whether the panel socket accepts a join for `id` (false while the Store restarts)."
  @spec panel_allowed?(String.t()) :: boolean()
  def panel_allowed?(id) when is_binary(id) do
    :ets.member(@panels, id)
  rescue
    ArgumentError -> false
  end

  @doc "The event `seq` of `sid`, or nil (also while the Store restarts)."
  @spec event(Session.sid(), pos_integer()) :: Event.t() | nil
  def event(sid, seq) do
    case :ets.lookup(@events, {sid, seq}) do
      [{_key, event}] -> event
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Returns the events of `sid` with a seq greater than `after_seq`, oldest first."
  @spec events(Session.sid(), non_neg_integer()) :: [Event.t()]
  def events(sid, after_seq \\ 0) do
    :ets.select(@events, [{{{sid, :"$1"}, :"$2"}, [{:>, :"$1", after_seq}], [:"$2"]}])
  end

  ## Limits and test helpers

  @spec limits() :: limits()
  def limits, do: :persistent_term.get(@limits_key, @default_limits)

  @doc false
  @spec default_limits() :: limits()
  def default_limits, do: @default_limits

  @doc false
  # Test helper: merges new limits. `:persistent_term` updates are expensive,
  # never call this on a hot path.
  @spec put_limits(map() | keyword()) :: :ok
  def put_limits(overrides) do
    :persistent_term.put(@limits_key, Map.merge(limits(), Map.new(overrides)))
  end

  @doc false
  # Runs the TTL sweep synchronously as of `now_us`.
  @spec sweep(integer()) :: :ok
  def sweep(now_us \\ System.system_time(:microsecond)),
    do: GenServer.call(Store, {:sweep, now_us})

  @doc false
  # Test helper: empties every table and restores the configured limits.
  @spec reset() :: :ok
  def reset, do: GenServer.call(Store, :reset)

  ## GenServer

  @impl GenServer
  def init(_opts) do
    Enum.each(@tables, fn table -> _ = :ets.new(table, table_opts(table)) end)
    :persistent_term.put(@seq_key, :atomics.new(1, signed: false))
    put_configured_limits()
    schedule_sweep()
    {:ok, %{monitors: %{}}}
  end

  @impl GenServer
  def handle_cast({:session_created, %Session{} = session}, state) do
    evict_oldest()
    {:noreply, maybe_monitor(state, session)}
  end

  def handle_cast({:monitor, sid, owner}, state) do
    {:noreply, monitor(state, sid, owner)}
  end

  def handle_cast({:trim, sid, {:plugin, _plugin} = scope}, state) do
    trim(sid, scope, limits().max_events)
    {:noreply, state}
  end

  def handle_cast({:trim, sid, :session}, state) do
    trim(sid, :session, limits().max_session_events)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:sweep, now_us}, _from, state) do
    do_sweep(now_us)
    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(@tables, &:ets.delete_all_objects/1)
    Enum.each(Map.keys(state.monitors), &Process.demonitor(&1, [:flush]))
    put_configured_limits()
    {:reply, :ok, %{state | monitors: %{}}}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {sid, monitors} = Map.pop(state.monitors, ref)
    _ = maybe_schedule_expire(sid, pid, limits().down_grace_ms)
    {:noreply, %{state | monitors: monitors}}
  end

  def handle_info({:expire, sid, pid}, state) do
    expire(sid, pid)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    do_sweep(System.system_time(:microsecond))
    schedule_sweep()
    {:noreply, state}
  end

  # A crash here would wipe every session: ignore anything unexpected.
  def handle_info(_message, state), do: {:noreply, state}

  ## Write path helpers (run in the caller)

  defp within_rate?(sid, second, max) do
    key = {sid, second}
    :ets.update_counter(@rate, key, 1, {key, 0}) <= max
  end

  defp do_insert(sid, %Event{plugin: plugin} = event, limits) do
    case bump(sid, 3) do
      nil ->
        :no_session

      count ->
        key = {sid, plugin}
        plugin_count = :ets.update_counter(@counts, key, {2, 1}, {key, 0, 0})
        seq = :atomics.add_get(:persistent_term.get(@seq_key), 1, 1)
        :ets.insert(@events, {{sid, seq}, %{event | sid: sid, seq: seq}})
        maybe_request_trim(sid, {:plugin, plugin}, plugin_count, limits.max_events)
        maybe_request_trim(sid, :session, count, limits.max_session_events)
        :ok
    end
  end

  defp count_dropped(sid) do
    case bump(sid, 4) do
      nil -> :no_session
      _dropped -> :dropped
    end
  end

  # Increments a counter of the session row, nil when the session is gone.
  defp bump(sid, position) do
    :ets.update_counter(@sessions, sid, {position, 1})
  rescue
    ArgumentError -> nil
  end

  defp maybe_request_trim(sid, scope, count, max)
       when count > max and rem(count - max, @trim_every) == 1,
       do: GenServer.cast(Store, {:trim, sid, scope})

  defp maybe_request_trim(_sid, _scope, _count, _max), do: :ok

  defp maybe_index_transport(%Session{transport: transport, sid: sid}) when is_pid(transport),
    do: :ets.insert(@transports, {transport, sid})

  defp maybe_index_transport(_session), do: true

  # Index lookups run on the host's hot path (attribution): while the Store
  # restarts its tables are missing, which simply means "not tracked".
  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, sid}] -> sid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  ## Housekeeping (run in the Store)

  # Deletes the oldest events of the scope (one plugin, or the whole session)
  # until it is back within `max`, and counts them as trimmed, per plugin and
  # for the session. Loops because concurrent inserts may land between reading
  # and decrementing; every round deletes at least one event or stops.
  defp trim(sid, scope, max) do
    with count when is_integer(count) and count > max <- scope_count(sid, scope),
         {rows, _cont} <- :ets.select(@events, trim_spec(sid, scope), count - max) do
      Enum.each(rows, fn {seq, _plugin} -> :ets.delete(@events, {sid, seq}) end)

      rows
      |> Enum.frequencies_by(fn {_seq, plugin} -> plugin end)
      |> Enum.each(fn {plugin, n} -> bump_plugin(sid, plugin, -n, n) end)

      trimmed = length(rows)
      bump_by(sid, 5, trimmed)
      bump_by(sid, 3, -trimmed)
      trim(sid, scope, max)
    end
  end

  defp scope_count(sid, :session) do
    case :ets.lookup(@sessions, sid) do
      [{^sid, _session, count, _dropped, _trimmed}] -> count
      [] -> nil
    end
  end

  defp scope_count(sid, {:plugin, plugin}) do
    case :ets.lookup(@counts, {sid, plugin}) do
      [{_key, count, _trimmed}] -> count
      [] -> nil
    end
  end

  # Oldest first: the events table is ordered by {sid, seq}. `{:const, plugin}`
  # keeps a plugin id such as :_ from being read as a match variable.
  defp trim_spec(sid, :session),
    do: [{{{sid, :"$1"}, %{plugin: :"$2"}}, [], [{{:"$1", :"$2"}}]}]

  defp trim_spec(sid, {:plugin, plugin}),
    do: [
      {{{sid, :"$1"}, %{plugin: :"$2"}}, [{:"=:=", :"$2", {:const, plugin}}], [{{:"$1", :"$2"}}]}
    ]

  defp bump_plugin(sid, plugin, count, trimmed) do
    :ets.update_counter(@counts, {sid, plugin}, [{2, count}, {3, trimmed}])
  rescue
    ArgumentError -> nil
  end

  defp bump_by(sid, position, amount) do
    _ = :ets.update_counter(@sessions, sid, {position, amount})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Sessions without a live LiveView owner go first (the tab the developer is
  # looking at is usually the oldest one), then by age. Never "the session that
  # triggered the check": casts may lag behind inserts.
  defp evict_oldest do
    excess = max(:ets.info(@sessions, :size) - limits().max_sessions, 0)

    sessions()
    |> Enum.sort_by(&{live_owner?(&1), &1.started_at})
    |> Enum.take(excess)
    |> Enum.each(&delete_session(&1.sid))
  end

  defp maybe_monitor(state, %Session{kind: :live_view, owner: owner, sid: sid})
       when is_pid(owner),
       do: monitor(state, sid, owner)

  defp maybe_monitor(state, _session), do: state

  defp monitor(state, sid, owner) do
    ref = Process.monitor(owner)
    %{state | monitors: Map.put(state.monitors, ref, sid)}
  end

  defp maybe_schedule_expire(nil, _pid, _grace), do: :ok
  defp maybe_schedule_expire(sid, pid, 0), do: expire(sid, pid)

  defp maybe_schedule_expire(sid, pid, grace),
    do: Process.send_after(self(), {:expire, sid, pid}, grace)

  # Only expires when the dead process still owns the session: a reconnected
  # LiveView claims it first (see claim/2).
  defp expire(sid, pid) do
    case :ets.lookup(@sessions, sid) do
      [{^sid, %Session{owner: ^pid}, _count, _dropped, _trimmed}] -> delete_session(sid)
      _ -> :ok
    end
  end

  defp do_sweep(now_us) do
    ttl_us = limits().ttl_ms * 1000

    for %Session{} = session <- sessions(),
        not live_owner?(session),
        now_us - last_activity(session) > ttl_us do
      delete_session(session.sid)
    end

    cutoff = System.monotonic_time(:second) - 1
    :ets.select_delete(@rate, [{{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}])
    delete_orphan_events()
    _ = delete_orphan_index_rows()
    expire_panels()
    :ok
  end

  defp expire_panels do
    cutoff = System.monotonic_time(:second) - @panel_ttl_s
    :ets.select_delete(@panels, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end

  # Index rows written after their session was deleted, and pid rows of
  # processes that exited (nested LiveViews, finished requests).
  defp delete_orphan_index_rows do
    for table <- [@pids, @socket_ids, @transports], row <- :ets.tab2list(table) do
      {key, sid} = {elem(row, 0), elem(row, 1)}
      _ = orphan_row?(table, key, sid) && :ets.delete(table, key)
    end

    # A counter row created by an insert racing with its session's deletion.
    for {{sid, _plugin} = key, _count, _trimmed} <- :ets.tab2list(@counts),
        not :ets.member(@sessions, sid),
        do: :ets.delete(@counts, key)
  end

  defp orphan_row?(table, key, sid) when table in [@pids, @transports],
    do: not :ets.member(@sessions, sid) or not Process.alive?(key)

  defp orphan_row?(_table, _key, sid), do: not :ets.member(@sessions, sid)

  # LiveView sessions with a running owner are cleaned up by DOWN, not by TTL:
  # an idle open tab keeps its data.
  defp live_owner?(%Session{kind: :live_view, owner: owner}) when is_pid(owner),
    do: Process.alive?(owner)

  defp live_owner?(_session), do: false

  defp last_activity(%Session{sid: sid, started_at: started_at}) do
    case :ets.prev(@events, {sid, :infinity}) do
      {^sid, _seq} = key -> :ets.lookup_element(@events, key, 2).at
      _ -> started_at
    end
  end

  # Events inserted while their session was being deleted. Walks one key per sid.
  defp delete_orphan_events, do: delete_orphan_events(:ets.first(@events))

  defp delete_orphan_events(:"$end_of_table"), do: :ok

  defp delete_orphan_events({sid, _seq}) do
    _ = :ets.member(@sessions, sid) || delete_events(sid)
    delete_orphan_events(:ets.next(@events, {sid, :infinity}))
  end

  defp delete_session(sid) do
    :ets.delete(@sessions, sid)
    delete_events(sid)
    :ets.match_delete(@counts, {{sid, :_}, :_, :_})
    :ets.match_delete(@pids, {:_, sid, :_})
    :ets.match_delete(@socket_ids, {:_, sid})
    :ets.match_delete(@transports, {:_, sid})
  end

  defp delete_events(sid), do: :ets.select_delete(@events, [{{{sid, :_}, :_}, [], [true]}])

  defp table_opts(@events), do: [:ordered_set | shared_opts()]
  defp table_opts(_table), do: [:set | shared_opts()]

  defp shared_opts, do: [:named_table, :public, read_concurrency: true, write_concurrency: true]

  defp put_configured_limits do
    configured = Application.get_env(:phoenix_dev_toolbar, :limits, [])
    :persistent_term.put(@limits_key, Config.limits(configured, @default_limits))
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, limits().sweep_ms)
end
