defmodule PhoenixDevToolbar.SuspenderTest do
  # Uses the application's Suspender (a named singleton).
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.ProcessHelpers

  alias PhoenixDevToolbar.Suspender

  defp suspended?(pid), do: Process.info(pid, :status) == {:status, :suspended}

  test "suspends for the TTL, then resumes" do
    pid = ponger()

    assert Suspender.suspend(pid, 200, self()) == :ok
    assert suspended?(pid)
    assert Map.has_key?(Suspender.suspended(), pid)

    send(pid, {:ping, self()})
    refute_receive {:pong, ^pid}, 50
    assert_receive {:pong, ^pid}, 1000
    refute Map.has_key?(Suspender.suspended(), pid)
  end

  test "resume/1 resumes at once; an unknown pid is not suspended" do
    pid = ponger()
    :ok = Suspender.suspend(pid, 60_000, self())

    assert Suspender.resume(pid) == :ok
    refute suspended?(pid)
    assert Suspender.resume(pid) == {:error, :not_suspended}
  end

  test "the owner going away resumes what it suspended" do
    pid = ponger()
    owner = idle_process()
    :ok = Suspender.suspend(pid, 60_000, owner)

    stop(owner)
    send(pid, {:ping, self()})

    assert_receive {:pong, ^pid}
  end

  test "a target that exits is forgotten" do
    pid = ponger()
    :ok = Suspender.suspend(pid, 60_000, self())
    ref = Process.monitor(pid)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    refute Map.has_key?(Suspender.suspended(), pid)
  end

  test "refuses twice the same, a dead one, a bad TTL, and more than ten" do
    # Earlier tests' suspensions end when their owner (that test) is gone.
    for {suspended, _deadline} <- Suspender.suspended(), do: Suspender.resume(suspended)
    pid = ponger()
    :ok = Suspender.suspend(pid, 60_000, self())
    assert Suspender.suspend(pid, 60_000, self()) == {:error, :already}

    dead = idle_process()
    stop(dead)
    assert Suspender.suspend(dead, 60_000, self()) == {:error, :dead}
    assert Suspender.suspend(ponger(), 99, self()) == {:error, :ttl}
    assert Suspender.suspend(ponger(), 60_001, self()) == {:error, :ttl}

    for _ <- 1..9, do: :ok = Suspender.suspend(ponger(), 60_000, self())
    assert Suspender.suspend(ponger(), 60_000, self()) == {:error, :too_many}

    for {suspended, _deadline} <- Suspender.suspended(), do: Suspender.resume(suspended)
  end

  test "a Suspender crash resumes everything it suspended" do
    pid = ponger()
    :ok = Suspender.suspend(pid, 60_000, self())
    suspender = Process.whereis(Suspender)
    ref = Process.monitor(suspender)

    Process.exit(suspender, :kill)
    assert_receive {:DOWN, ^ref, :process, ^suspender, :killed}

    send(pid, {:ping, self()})
    assert_receive {:pong, ^pid}

    # The supervisor has restarted it before the next test (a sync call to it
    # runs after it handled the exit).
    _ = Supervisor.which_children(PhoenixDevToolbar.Supervisor)
    assert is_pid(Process.whereis(Suspender))
  end
end
