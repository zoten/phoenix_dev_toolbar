defmodule PhoenixDevToolbar.TracerTest do
  # Uses the application's Tracer (one trace on the node at a time).
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.ProcessHelpers

  alias PhoenixDevToolbar.Tracer

  @moduletag :trace_sessions

  # Answers pings, so it both receives and sends.
  defp ponger do
    pid = spawn(fn -> pong() end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp pong do
    receive do
      {:ping, from, payload} -> send(from, {:pong, payload})
    end

    pong()
  end

  # The Tracer has handled every trace message sent before this call. A DOWN
  # comes from another sender: the Tracer may get it after a later call, so
  # the tests that wait on one sync with it first.
  defp status(owner \\ self()), do: Tracer.status(owner)

  defp sync, do: _ = :sys.get_state(Tracer)

  setup do
    on_exit(fn -> Tracer.stop(self()) end)
  end

  test "records what the process receives and sends, redacted" do
    pid = ponger()
    assert Tracer.start(pid, self()) == :ok

    send(pid, {:ping, self(), %{password: "hunter2", name: "Ada"}})
    assert_receive {:pong, _payload}

    assert %{running?: true, events: [received, sent]} = status()
    assert %{dir: :in, peer: nil, message: message} = received
    assert message =~ "Ada"
    assert message =~ "[REDACTED]"
    refute message =~ "hunter2"
    assert %{dir: :out, peer: me} = sent
    assert me == self()
  end

  test "stops by itself at the message limit" do
    pid = ponger()
    :ok = Tracer.start(pid, self())

    for n <- 1..Tracer.max_events(), do: send(pid, {:ping, self(), n})
    for _ <- 1..Tracer.max_events(), do: assert_receive({:pong, _n})

    assert %{running?: false, stopped: :limit, events: events} = status()
    assert length(events) == Tracer.max_events()

    send(pid, {:ping, self(), :after})
    assert_receive {:pong, :after}
    assert length(status().events) == Tracer.max_events()
  end

  test "stops when the process exits; Stop keeps what it recorded" do
    pid = idle_process()
    :ok = Tracer.start(pid, self())
    send(pid, :hello)
    stop(pid)
    sync()

    assert %{running?: false, stopped: :exited, events: [%{message: ":hello"} | _rest]} =
             status()

    pinged = ponger()
    :ok = Tracer.start(pinged, self())
    :ok = Tracer.stop(self())
    send(pinged, {:ping, self(), :untraced})
    assert_receive {:pong, :untraced}

    assert %{running?: false, stopped: :stopped, events: []} = status()
  end

  test "one trace on the node: another panel is told it is busy" do
    pid = ponger()
    :ok = Tracer.start(pid, self())
    other = idle_process()

    assert Tracer.start(pid, other) == {:error, :busy}
    assert status(other) == nil
  end

  test "the panel going away clears its trace" do
    pid = ponger()
    owner = idle_process()
    :ok = Tracer.start(pid, owner)

    stop(owner)
    sync()

    assert status(owner) == nil
    assert Tracer.start(pid, self()) == :ok
  end

  test "an exited process cannot be traced" do
    pid = idle_process()
    stop(pid)

    assert Tracer.start(pid, self()) == {:error, :dead}
  end
end
