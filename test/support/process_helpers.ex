defmodule PhoenixDevToolbar.ProcessHelpers do
  @moduledoc false
  # Runs code in a separate, long lived process, as a request or LiveView
  # process would. The process stays alive until the test exits or `stop/1`.

  import ExUnit.Assertions
  import ExUnit.Callbacks

  @spec in_process((-> result)) :: {pid(), result} when result: term()
  def in_process(fun) do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:in_process_done, self(), fun.()})
        receive(do: (:stop -> :ok))
      end)

    on_exit(fn -> send(pid, :stop) end)
    _ = assert_receive {:in_process_done, ^pid, result}
    {pid, result}
  end

  @spec idle_process() :: pid()
  def idle_process do
    {pid, :ok} = in_process(fn -> :ok end)
    pid
  end

  @doc "Runs `fun` in a long lived process tracked as session `sid`, like `in_process/1`."
  @spec tracked(String.t(), (-> result)) :: {pid(), result} when result: term()
  def tracked(sid, fun) do
    in_process(fn ->
      PhoenixDevToolbar.Attribution.track(sid)
      fun.()
    end)
  end

  @doc "A process that has already exited."
  @spec dead_process() :: pid()
  def dead_process do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    # :noproc when it exited before the monitor was set.
    _ = assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end

  @doc """
  Terminates the Store child of the toolbar's supervisor for this test and
  restarts it on exit.
  """
  @spec stop_store!() :: :ok
  def stop_store! do
    :ok = Supervisor.terminate_child(PhoenixDevToolbar.Supervisor, PhoenixDevToolbar.Store)

    on_exit(fn ->
      Supervisor.restart_child(PhoenixDevToolbar.Supervisor, PhoenixDevToolbar.Store)
    end)
  end

  @doc """
  Gives this test its own copy of `child` (a child spec or module of the
  toolbar's supervisor): the supervisor's one is terminated and restarted on
  exit, so a crash test spends no restart intensity of the toolbar's
  supervisor. Returns the pid of the test's copy.
  """
  @spec own_copy!(module() | Supervisor.child_spec()) :: pid()
  def own_copy!(child) do
    id = if is_atom(child), do: child, else: child.id
    :ok = Supervisor.terminate_child(PhoenixDevToolbar.Supervisor, id)

    on_exit(fn ->
      {:ok, _pid} = Supervisor.restart_child(PhoenixDevToolbar.Supervisor, id)
    end)

    start_supervised!(child)
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    _ = assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    :ok
  end

  @doc """
  A process that answers pings, so it both receives and sends: `{:ping, from}`
  gets `{:pong, pid}`, `{:ping, from, payload}` gets `{:pong, payload}`. A
  suspended one answers only once resumed. Killed on exit.
  """
  @spec ponger() :: pid()
  def ponger do
    pid = spawn(fn -> pong() end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp pong do
    receive do
      {:ping, from} -> send(from, {:pong, self()})
      {:ping, from, payload} -> send(from, {:pong, payload})
    end

    pong()
  end

  @doc """
  Polls `fun` until it is truthy, then returns. Flunks after `timeout_ms` (a
  monotonic deadline). Yields between polls: no sleep, no fixed iteration count.
  """
  @spec wait_until((-> as_boolean(term())), pos_integer()) :: :ok
  def wait_until(fun, timeout_ms \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(fun, deadline, timeout_ms)
  end

  defp poll(fun, deadline, timeout_ms) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within #{timeout_ms} ms")

      true ->
        receive do
        after
          1 -> poll(fun, deadline, timeout_ms)
        end
    end
  end
end
