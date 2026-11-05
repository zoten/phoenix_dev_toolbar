defmodule PhoenixDevToolbar.CollectorTest do
  # Telemetry handlers and the Store are node global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import PhoenixDevToolbar.ProcessHelpers

  alias PhoenixDevToolbar.Attribution
  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.TestPlugins.BadEvents
  alias PhoenixDevToolbar.TestPlugins.Configured
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.TestPlugins.Echo
  alias PhoenixDevToolbar.TestPlugins.Raising

  @event [:pdt_test, :echo]

  setup do
    Store.reset()

    on_exit(fn ->
      Collector.attach(PhoenixDevToolbar.Application.plugins())
      Store.reset()
    end)

    %Session{sid: sid} = Store.new_session(Session.new(:request))
    %{sid: sid}
  end

  defp emit(metadata), do: :telemetry.execute(@event, %{}, metadata)

  defp tracked(sid, fun) do
    in_process(fn ->
      Attribution.track(sid)
      fun.()
    end)
  end

  test "ignores events from untracked processes", %{sid: sid} do
    Collector.attach([Echo])

    in_process(fn -> emit(%{value: 1}) end)

    assert Store.events(sid) == []
  end

  test "records events from tracked processes and notifies subscribers", %{sid: sid} do
    Collector.attach([Echo])
    Notify.subscribe(sid)

    tracked(sid, fn -> emit(%{value: 1}) end)

    assert [%Event{plugin: :echo, data: %{value: 1, source: :self}}] = Store.events(sid)
    assert_receive {:pdt_event, ^sid}
  end

  test "attributes Task.async children to the caller's session", %{sid: sid} do
    Collector.attach([Echo])

    tracked(sid, fn -> fn -> emit(%{value: 2}) end |> Task.async() |> Task.await() end)

    assert [%Event{data: %{value: 2, source: :caller}}] = Store.events(sid)
  end

  test "records nothing when the plugin skips", %{sid: sid} do
    Collector.attach([Echo])

    tracked(sid, fn -> emit(%{skip: true}) end)

    assert Store.events(sid) == []
  end

  test "quarantines a raising plugin, logs once and keeps the others working", %{sid: sid} do
    Collector.attach([Raising, Echo])

    log = capture_log(fn -> tracked(sid, fn -> emit(%{value: 1}) end) end)

    assert log =~ "PhoenixDevToolbar.TestPlugins.Raising"
    assert Collector.quarantined?(Raising)
    assert [%{id: {Collector, @event}}] = :telemetry.list_handlers(@event)

    assert capture_log(fn -> tracked(sid, fn -> emit(%{value: 2}) end) end) == ""
    assert sid |> Store.events() |> Enum.map(& &1.data.value) == [1, 2]
  end

  test "attach/1 releases quarantined plugins", %{sid: sid} do
    capture_log(fn ->
      Collector.attach([Raising])
      tracked(sid, fn -> emit(%{}) end)
    end)

    assert Collector.quarantined?(Raising)

    Collector.attach([Raising])

    refute Collector.quarantined?(Raising)
  end

  test "hands each plugin its init/1 config, and lists the attached plugins", %{sid: sid} do
    Collector.attach([{Configured, label: "from opts"}, Echo])

    tracked(sid, fn -> emit(%{value: 1}) end)

    assert [{Configured, %{label: "from opts"}}, {Echo, []}] = Collector.plugins()

    assert [%Event{plugin: :configured, data: %{label: "from opts"}}, %Event{plugin: :echo}] =
             Store.events(sid)
  end

  test "leaves out, with an error log, a plugin whose init/1 fails", %{sid: sid} do
    log = capture_log(fn -> Collector.attach([{Configured, label: 1}, Echo]) end)

    assert log =~ "Configured is disabled: init/1 returned an error: label must be a string"
    assert [{Echo, []}] = Collector.plugins()

    tracked(sid, fn -> emit(%{value: 1}) end)
    assert [%Event{plugin: :echo}] = Store.events(sid)
  end

  test "skips a plugin with malformed event names instead of failing the attach", %{sid: sid} do
    log =
      capture_log(fn ->
        assert Collector.attach([{BadEvents, events: [["not", "atoms"]]}, Echo]) == :ok
        assert Collector.attach([{BadEvents, events: [[]]}, Echo]) == :ok
      end)

    assert log =~ "telemetry_events/1 must return lists of atoms"
    assert [{Echo, []}] = Collector.plugins()

    tracked(sid, fn -> emit(%{value: 1}) end)
    assert [%Event{plugin: :echo}] = Store.events(sid)
  end

  test "an event name listed twice by a plugin records once", %{sid: sid} do
    Collector.attach([{BadEvents, events: [@event, @event]}])

    tracked(sid, fn -> emit(%{}) end)

    assert [%Event{plugin: :bad_events}] = Store.events(sid)
  end

  test "the handler config holds module names only, never plugin configs" do
    Collector.attach([{Configured, label: String.duplicate("x", 1000)}])

    assert [%{config: [Configured]}] = :telemetry.list_handlers(@event)
  end

  test "garbage entries given to attach/1 directly are skipped" do
    log = capture_log(fn -> assert Collector.attach(["nope", {Echo, :x}, Echo]) == :ok end)

    assert log =~ "expected Module or {Module, opts}"
    assert [{Echo, []}] = Collector.plugins()
  end

  test "detach/0 removes every toolbar handler" do
    Collector.attach([Echo])

    Collector.detach()

    assert for(%{id: {Collector, _}} = handler <- :telemetry.list_handlers([]), do: handler) == []
  end
end
