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
  #   :pdt_sessions    set          {sid, %Session{}, count, dropped}
  #   :pdt_pids        set          {pid, sid}            ($callers attribution)
  #   :pdt_socket_ids  set          {socket_id, sid}      (dead render -> LiveView)
  #   :pdt_transports  set          {transport_pid, sid}  (latest sid per tab)
  #   :pdt_rate        set          {{sid, second}, n}    (flood guard)

  use GenServer

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @events :pdt_events
  @sessions :pdt_sessions
  @pids :pdt_pids
  @socket_ids :pdt_socket_ids
  @transports :pdt_transports
  @rate :pdt_rate
  @tables [@events, @sessions, @pids, @socket_ids, @transports, @rate]

  @limits_key {Store, :limits}
  @seq_key {Store, :seq}

  # After the first overflow, re-request a trim every @trim_every inserts.
  @trim_every 64

  @default_limits %{
    max_events: 500,
    max_sessions: 50,
    ttl_ms: :timer.minutes(10),
    sweep_ms: :timer.seconds(30),
    events_per_second: 200,
    down_grace_ms: :timer.seconds(60)
  }

  @type limits :: %{
          max_events: pos_integer(),
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
    :ets.insert(@sessions, {sid, session, 0, 0})
    maybe_index_transport(session)
    GenServer.cast(Store, {:session_created, session})
    session
  end

  @doc "Returns the session with its counters."
  @spec session(Session.sid()) :: {:ok, Session.t()} | :error
  def session(sid) do
    case :ets.lookup(@sessions, sid) do
      [{^sid, session, count, dropped}] -> {:ok, %{session | count: count, dropped: dropped}}
      [] -> :error
    end
  end

  @doc "Lists all sessions, oldest first."
  @spec sessions() :: [Session.t()]
  def sessions do
    @sessions
    |> :ets.tab2list()
    |> Enum.map(fn {_sid, session, count, dropped} ->
      %{session | count: count, dropped: dropped}
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
      [{^sid, session, _count, _dropped}] ->
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
  @spec track_pid(pid(), Session.sid()) :: true
  def track_pid(pid, sid) when is_pid(pid), do: :ets.insert(@pids, {pid, sid})

  @spec untrack_pid(pid()) :: true
  def untrack_pid(pid) when is_pid(pid), do: :ets.delete(@pids, pid)

  @spec sid_for_pid(pid()) :: Session.sid() | nil
  def sid_for_pid(pid), do: lookup(@pids, pid)

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
      true -> do_insert(sid, event, limits.max_events)
      false -> count_dropped(sid)
    end
  rescue
    # Tables missing while the Store restarts: the event is lost, nothing else.
    ArgumentError -> :no_session
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

  @impl true
  def init(_opts) do
    for table <- @tables, do: :ets.new(table, table_opts(table))
    :persistent_term.put(@seq_key, :atomics.new(1, signed: false))
    put_configured_limits()
    schedule_sweep()
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_cast({:session_created, %Session{} = session}, state) do
    evict_oldest()
    {:noreply, maybe_monitor(state, session)}
  end

  def handle_cast({:monitor, sid, owner}, state) do
    {:noreply, monitor(state, sid, owner)}
  end

  def handle_cast({:trim, sid}, state) do
    trim(sid, limits().max_events)
    {:noreply, state}
  end

  @impl true
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

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {sid, monitors} = Map.pop(state.monitors, ref)
    maybe_schedule_expire(sid, pid, limits().down_grace_ms)
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

  defp do_insert(sid, event, max_events) do
    case bump(sid, 3) do
      nil ->
        :no_session

      count ->
        seq = :atomics.add_get(:persistent_term.get(@seq_key), 1, 1)
        :ets.insert(@events, {{sid, seq}, %{event | sid: sid, seq: seq}})
        maybe_request_trim(sid, count, max_events)
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

  defp maybe_request_trim(sid, count, max)
       when count > max and rem(count - max, @trim_every) == 1,
       do: GenServer.cast(Store, {:trim, sid})

  defp maybe_request_trim(_sid, _count, _max), do: :ok

  defp maybe_index_transport(%Session{transport: transport, sid: sid}) when is_pid(transport),
    do: :ets.insert(@transports, {transport, sid})

  defp maybe_index_transport(_session), do: true

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, sid}] -> sid
      [] -> nil
    end
  end

  ## Housekeeping (run in the Store)

  # Deletes the oldest events until the session is back within `max`. Loops
  # because concurrent inserts may land between reading and decrementing.
  defp trim(sid, max) do
    with [{^sid, _session, count, _dropped}] when count > max <- :ets.lookup(@sessions, sid),
         {seqs, _cont} <- :ets.select(@events, [{{{sid, :"$1"}, :_}, [], [:"$1"]}], count - max) do
      Enum.each(seqs, &:ets.delete(@events, {sid, &1}))
      maybe_trim_again(sid, max, bump_by(sid, 3, -length(seqs)))
    end
  end

  defp maybe_trim_again(sid, max, count) when is_integer(count) and count > max,
    do: trim(sid, max)

  defp maybe_trim_again(_sid, _max, _count), do: :ok

  defp bump_by(sid, position, amount) do
    :ets.update_counter(@sessions, sid, {position, amount})
  rescue
    ArgumentError -> nil
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
      [{^sid, %Session{owner: ^pid}, _count, _dropped}] -> delete_session(sid)
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
    delete_orphan_index_rows()
    :ok
  end

  # Index rows written after their session was deleted, and pid rows of
  # processes that exited (nested LiveViews, finished requests).
  defp delete_orphan_index_rows do
    for table <- [@pids, @socket_ids, @transports], {key, sid} <- :ets.tab2list(table) do
      _ = orphan_row?(table, key, sid) && :ets.delete(table, key)
    end
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
    :ets.match_delete(@pids, {:_, sid})
    :ets.match_delete(@socket_ids, {:_, sid})
    :ets.match_delete(@transports, {:_, sid})
  end

  defp delete_events(sid), do: :ets.select_delete(@events, [{{{sid, :_}, :_}, [], [true]}])

  defp table_opts(@events), do: [:ordered_set | shared_opts()]
  defp table_opts(_table), do: [:set | shared_opts()]

  defp shared_opts, do: [:named_table, :public, read_concurrency: true, write_concurrency: true]

  defp put_configured_limits do
    configured = Application.get_env(:phoenix_dev_toolbar, :limits, [])
    :persistent_term.put(@limits_key, Map.merge(@default_limits, Map.new(configured)))
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, limits().sweep_ms)
end
