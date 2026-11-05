defmodule PhoenixDevToolbar.CollectorTest do
  # Telemetry handlers and the Store are node global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import PhoenixDevToolbar.ProcessHelpers

  alias PhoenixDevToolbar.Attribution
  alias PhoenixDevToolbar.Collector
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

  test "detach/0 removes every toolbar handler" do
    Collector.attach([Echo])

    Collector.detach()

    assert for(%{id: {Collector, _}} = handler <- :telemetry.list_handlers([]), do: handler) == []
  end
end
