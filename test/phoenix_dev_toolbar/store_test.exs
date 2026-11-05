defmodule PhoenixDevToolbar.StoreTest do
  # The Store owns named ETS tables shared by the whole node.
  use ExUnit.Case, async: false

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
  end

  defp event(n \\ 0, at \\ System.system_time(:microsecond)),
    do: Event.new(:test, :ping, %{n: n}, at: at)

  defp sync_store, do: _ = :sys.get_state(Store)

  defp start_owner do
    pid = spawn(fn -> receive(do: (:stop -> :ok)) end)
    on_exit(fn -> send(pid, :stop) end)
    pid
  end

  defp stop_owner(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    sync_store()
  end

  describe "insert/2 and events/2" do
    test "stores events in insertion order with increasing seqs" do
      %Session{sid: sid} = Store.new_session(Session.new(:request))

      for n <- 1..3, do: assert(Store.insert(sid, event(n)) == :ok)

      events = Store.events(sid)
      assert Enum.map(events, & &1.data.n) == [1, 2, 3]
      assert Enum.all?(events, &(&1.sid == sid))

      [_first, second, third] = events
      assert Store.events(sid, second.seq) == [third]
      assert {:ok, %Session{count: 3, dropped: 0}} = Store.session(sid)
    end

    test "keeps sessions apart" do
      %Session{sid: a} = Store.new_session(Session.new(:request))
      %Session{sid: b} = Store.new_session(Session.new(:request))

      Store.insert(a, event(1))
      Store.insert(b, event(2))

      assert [%Event{data: %{n: 1}}] = Store.events(a)
      assert [%Event{data: %{n: 2}}] = Store.events(b)
    end

    test "refuses events for unknown sessions" do
      assert Store.insert("missing", event()) == :no_session
      assert Store.events("missing") == []
    end
  end

  describe "caps" do
    test "trims the oldest events of a plugin down to max_events" do
      Store.put_limits(max_events: 5)
      %Session{sid: sid} = Store.new_session(Session.new(:request))

      for n <- 1..10, do: Store.insert(sid, event(n))
      sync_store()

      assert Enum.map(Store.events(sid), & &1.data.n) == [6, 7, 8, 9, 10]
      assert {:ok, %Session{count: 5, trimmed: 5}} = Store.session(sid)
      assert Store.plugin_counts(sid) == %{test: %{count: 5, trimmed: 5}}
    end

    test "a chatty plugin never trims another plugin's events" do
      Store.put_limits(max_events: 3)
      %Session{sid: sid} = Store.new_session(Session.new(:request))

      Store.insert(sid, Event.new(:quiet, :ping, %{n: :kept}))
      for n <- 1..10, do: Store.insert(sid, Event.new(:chatty, :ping, %{n: n}))
      sync_store()

      assert sid |> Store.events() |> Enum.map(&{&1.plugin, &1.data.n}) ==
               [quiet: :kept, chatty: 8, chatty: 9, chatty: 10]

      assert Store.plugin_counts(sid) == %{
               quiet: %{count: 1, trimmed: 0},
               chatty: %{count: 3, trimmed: 7}
             }
    end

    test "the session ceiling trims the oldest events of any plugin" do
      Store.put_limits(max_events: 10, max_session_events: 4)
      %Session{sid: sid} = Store.new_session(Session.new(:request))

      for n <- 1..3, do: Store.insert(sid, Event.new(:a, :ping, %{n: n}))
      for n <- 4..6, do: Store.insert(sid, Event.new(:b, :ping, %{n: n}))
      sync_store()

      assert sid |> Store.events() |> Enum.map(& &1.data.n) == [3, 4, 5, 6]
      assert {:ok, %Session{count: 4, trimmed: 2}} = Store.session(sid)

      assert Store.plugin_counts(sid) == %{
               a: %{count: 1, trimmed: 2},
               b: %{count: 3, trimmed: 0}
             }
    end

    test "a plugin id that looks like a match variable is trimmed as a plain atom" do
      Store.put_limits(max_events: 1)
      %Session{sid: sid} = Store.new_session(Session.new(:request))

      Store.insert(sid, Event.new(:other, :ping, %{n: 0}))
      for n <- 1..3, do: Store.insert(sid, Event.new(:_, :ping, %{n: n}))
      sync_store()

      assert sid |> Store.events() |> Enum.map(& &1.data.n) == [0, 3]
      assert %{other: %{count: 1, trimmed: 0}} = Store.plugin_counts(sid)

      Store.insert(sid, Event.new(:"$1", :ping, %{n: 4}))
      Store.insert(sid, Event.new(:"$1", :ping, %{n: 5}))
      sync_store()

      assert sid |> Store.events() |> Enum.map(& &1.data.n) == [0, 3, 5]
    end

    test "one insert can trigger both trims; per plugin trimmed adds up to the page's" do
      Store.put_limits(max_events: 3, max_session_events: 5)
      %Session{sid: sid} = Store.new_session(Session.new(:request))

      for n <- 1..3, do: Store.insert(sid, Event.new(:a, :ping, %{n: n}))
      for n <- 4..7, do: Store.insert(sid, Event.new(:b, :ping, %{n: n}))
      sync_store()

      assert {:ok, %Session{count: count, trimmed: trimmed}} = Store.session(sid)
      counts = Store.plugin_counts(sid)

      assert count == length(Store.events(sid))
      assert count <= 5
      assert trimmed == counts |> Map.values() |> Enum.map(& &1.trimmed) |> Enum.sum()
      assert counts.b.count == 3
    end

    test "the sweep deletes counter rows whose session is gone" do
      :ets.insert(:pdt_counts, {{"ghost", :test}, 1, 0})

      Store.sweep()

      assert Store.plugin_counts("ghost") == %{}
    end

    test "an expired session takes its counters along" do
      %Session{sid: sid} = Store.new_session(Session.new(:request))
      Store.insert(sid, event(1))
      assert %{test: _} = Store.plugin_counts(sid)

      Store.sweep(System.system_time(:microsecond) + :timer.hours(1) * 1000)

      assert Store.session(sid) == :error
      assert Store.plugin_counts(sid) == %{}
    end
  end

  describe "flood guard" do
    test "drops events over the per-second budget and counts them" do
      Store.put_limits(events_per_second: 3)
      %Session{sid: sid} = Store.new_session(Session.new(:request))

      results = for n <- 1..5, do: Store.insert(sid, event(n), 1_000)

      assert results == [:ok, :ok, :ok, :dropped, :dropped]
      assert {:ok, %Session{count: 3, dropped: 2}} = Store.session(sid)
    end

    test "starts a fresh budget every second" do
      Store.put_limits(events_per_second: 1)
      %Session{sid: sid} = Store.new_session(Session.new(:request))

      assert Store.insert(sid, event(), 1_000) == :ok
      assert Store.insert(sid, event(), 1_001) == :ok
    end
  end

  describe "session eviction" do
    test "evicts the oldest sessions beyond max_sessions" do
      Store.put_limits(max_sessions: 2)

      [old, mid, new] =
        for at <- [1, 2, 3] do
          session = %{Session.new(:request) | started_at: at}
          Store.new_session(session).sid
        end

      sync_store()

      assert Store.session(old) == :error
      assert {:ok, _} = Store.session(mid)
      assert {:ok, _} = Store.session(new)
    end

    test "evicts sessions without a live LiveView owner first" do
      Store.put_limits(max_sessions: 2)

      open_tab =
        Store.new_session(%{Session.new(:live_view, owner: start_owner()) | started_at: 1}).sid

      [old_request, new_request] =
        for at <- [2, 3], do: Store.new_session(%{Session.new(:request) | started_at: at}).sid

      sync_store()

      assert {:ok, _} = Store.session(open_tab)
      assert Store.session(old_request) == :error
      assert {:ok, _} = Store.session(new_request)
    end
  end

  describe "LiveView owner DOWN" do
    setup do
      Store.put_limits(down_grace_ms: 0)
      :ok
    end

    test "drops the session and its indexes when the owner exits" do
      owner = start_owner()
      transport = start_owner()

      %Session{sid: sid} =
        Store.new_session(Session.new(:live_view, owner: owner, transport: transport))

      Store.insert(sid, event())
      Store.track_pid(owner, sid)
      Store.link_socket_id("phx-abc", sid)
      sync_store()

      assert Store.latest_for_transport(transport) == sid

      stop_owner(owner)

      assert Store.session(sid) == :error
      assert Store.events(sid) == []
      assert Store.sid_for_pid(owner) == nil
      assert Store.sid_for_socket_id("phx-abc") == nil
      assert Store.latest_for_transport(transport) == nil
    end

    test "keeps a session claimed by a new owner" do
      old_owner = start_owner()
      %Session{sid: sid} = Store.new_session(Session.new(:live_view, owner: old_owner))
      sync_store()

      new_owner = start_owner()
      assert {:ok, %Session{owner: ^new_owner}} = Store.claim(sid, new_owner, nil)

      stop_owner(old_owner)

      assert {:ok, %Session{owner: ^new_owner}} = Store.session(sid)
    end
  end

  describe "pids_for/1" do
    test "lists the processes tracked as a session" do
      %Session{sid: sid} = Store.new_session(Session.new(:live_view))
      %Session{sid: other} = Store.new_session(Session.new(:live_view))
      [a, b, c] = for _ <- 1..3, do: start_owner()
      Store.track_pid(a, sid)
      Store.track_pid(b, sid)
      Store.track_pid(c, other)

      assert Enum.sort(Store.pids_for(sid)) == Enum.sort([a, b])
    end
  end

  describe "sweep/1 index cleanup" do
    test "drops index rows of missing sessions and pid rows of dead processes" do
      %Session{sid: sid} = Store.new_session(Session.new(:request))
      dead = start_owner()
      alive = start_owner()
      Store.track_pid(dead, sid)
      Store.track_pid(alive, sid)
      Store.link_socket_id("phx-gone", "missing-sid")
      stop_owner(dead)

      Store.sweep()

      assert Store.sid_for_pid(dead) == nil
      assert Store.sid_for_pid(alive) == sid
      assert Store.sid_for_socket_id("phx-gone") == nil
    end
  end

  describe "sweep/1" do
    test "expires idle request sessions after the TTL, measured from the last event" do
      Store.put_limits(ttl_ms: 1_000)
      now = System.system_time(:microsecond)

      %Session{sid: idle} = Store.new_session(%{Session.new(:request) | started_at: now})
      %Session{sid: active} = Store.new_session(%{Session.new(:request) | started_at: now})
      Store.insert(active, event(1, now + 2_000_000))

      Store.sweep(now + 2_500_000)

      assert Store.session(idle) == :error
      assert {:ok, _} = Store.session(active)
    end

    test "never expires a LiveView session whose owner is alive" do
      Store.put_limits(ttl_ms: 0)
      %Session{sid: sid} = Store.new_session(Session.new(:live_view, owner: start_owner()))

      Store.sweep(System.system_time(:microsecond) + 60_000_000)

      assert {:ok, _} = Store.session(sid)
    end
  end
end
