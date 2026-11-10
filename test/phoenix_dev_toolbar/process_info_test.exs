defmodule PhoenixDevToolbar.ProcessInfoTest do
  use ExUnit.Case, async: true

  import PhoenixDevToolbar.ProcessHelpers

  alias PhoenixDevToolbar.ProcessInfo

  defp idle, do: receive(do: (:stop -> :ok))

  # A process that links a Task child (started: its $callers is set), monitors
  # another process, and waits.
  defp subject do
    test = self()

    pid =
      spawn(fn ->
        child =
          Task.async(fn ->
            send(test, {:child_started, self()})
            idle()
          end)

        stranger = spawn(fn -> idle() end)
        Process.monitor(stranger)
        send(test, {:ready, child.pid, stranger})
        idle()
      end)

    assert_receive {:ready, child, stranger}
    assert_receive {:child_started, ^child}
    on_exit(fn -> for p <- [pid, child, stranger], do: send(p, :stop) end)
    {pid, child, stranger}
  end

  test "a sample has the vital signs, read without the message queue" do
    {pid, _child, _stranger} = subject()
    for n <- 1..1000, do: send(pid, {:junk, n})

    assert {:ok, sample} = ProcessInfo.sample(pid)
    assert sample.message_queue_len == 1000
    assert sample.memory > 0 and sample.reductions > 0
    assert is_integer(sample.minor_gcs)
    assert sample.status in [:waiting, :running, :runnable]
    assert sample.current_function =~ "/"
  end

  test "reductions per second come from two samples" do
    assert ProcessInfo.reductions_per_second(%{at: 0, reductions: 100}, %{
             at: 500,
             reductions: 600
           }) ==
             1000

    assert ProcessInfo.reductions_per_second(%{at: 5, reductions: 1}, %{at: 5, reductions: 9}) ==
             0
  end

  test "relations name each process and mark $callers children" do
    {pid, child, stranger} = subject()

    # Task.async links and monitors its child; the stranger is only monitored.
    assert %{links: links, monitors: monitors, more: %{links: 0}} = ProcessInfo.relations(pid)

    assert %{kind: :process, child?: true, name: name} =
             Enum.find(links, &(&1.id == inspect(child)))

    assert %{child?: true} = Enum.find(monitors, &(&1.id == inspect(child)))

    assert %{child?: false, name: stranger_name} =
             Enum.find(monitors, &(&1.id == inspect(stranger)))

    # A Task is named after its function, a plain spawn after what it runs now.
    assert name =~ "ProcessInfoTest"
    refute name =~ "Task.Supervised"
    refute stranger_name == ":erlang.apply/2"
  end

  test "a GenServer is named after $initial_call, not proc_lib" do
    agent = start_supervised!({Agent, fn -> :state end})
    {:initial_call, {:proc_lib, :init_p, _arity}} = Process.info(agent, :initial_call)
    assert %{initial_call: name, trap_exit: false} = ProcessInfo.about(agent)
    assert name =~ "in PhoenixDevToolbar.ProcessInfoTest"
  end

  test "a supervisor is named after its module" do
    sup = start_supervised!({Task.Supervisor, name: __MODULE__.Sup})
    assert ProcessInfo.about(sup).initial_call == "Task.Supervisor (supervisor)"
  end

  test "a linked port is listed as a port" do
    test = self()

    pid =
      spawn(fn ->
        port = Port.open({:spawn, "cat"}, [])
        send(test, {:port, port})
        idle()
      end)

    assert_receive {:port, port}
    on_exit(fn -> Process.exit(pid, :kill) end)

    assert %{links: [%{kind: :port, id: id, name: name, child?: false}]} =
             ProcessInfo.relations(pid)

    assert id == inspect(port)
    assert name =~ "cat"
  end

  test "relations are capped at 50 of each, the rest counted" do
    others = for _n <- 1..60, do: spawn(fn -> idle() end)
    test = self()

    linker =
      spawn(fn ->
        for other <- others, do: Process.link(other)
        send(test, :linked)
        idle()
      end)

    assert_receive :linked
    on_exit(fn -> for p <- [linker | others], do: Process.exit(p, :kill) end)

    assert %{links: links, more: %{links: 10}} = ProcessInfo.relations(linker)
    assert length(links) == 50
  end

  test "collect/1 garbage collects and reports memory before and after" do
    test = self()

    pid =
      spawn(fn ->
        # Garbage: a big list built and dropped, left on the heap until a GC.
        _ = Enum.to_list(1..200_000) |> length()
        send(test, :garbage)
        idle()
      end)

    assert_receive :garbage
    on_exit(fn -> send(pid, :stop) end)

    assert {:ok, before, after_gc} = ProcessInfo.collect(pid)
    assert after_gc < before

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _reason}
    assert ProcessInfo.collect(dead) == :dead
  end

  test "a dead process reads as dead, never raises" do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    # :noproc when it exited before the monitor was set.
    assert_receive {:DOWN, ^ref, :process, ^pid, _normal_or_noproc}

    assert ProcessInfo.sample(pid) == :dead
    assert ProcessInfo.about(pid) == nil
    assert ProcessInfo.relations(pid) == nil
  end

  describe "ancestors/1" do
    test "a proc_lib process lists who started it, nearest first, as links" do
      agent = start_supervised!({Agent, fn -> :ok end})
      [nearest | _rest] = ProcessInfo.ancestors(agent)

      # start_supervised!/1 starts it under the test's supervisor.
      assert [{:links, [supervisor | _links]}] = Process.info(agent, [:links])
      assert %{pid: ^supervisor, id: id} = nearest
      assert id == inspect(supervisor)
    end

    test "a plain process falls back to its parent" do
      test = self()
      {pid, :ok} = in_process(fn -> :ok end)

      assert [%{pid: ^test}] = ProcessInfo.ancestors(pid)
    end
  end

  test "stacktrace/1 tells where the process waits, at most 20 frames" do
    frames = ProcessInfo.stacktrace(idle_process())

    assert frames != []
    assert length(frames) <= 20
    assert Enum.all?(frames, &is_binary/1)
  end

  test "otp?/1 tells proc_lib processes from plain ones" do
    assert ProcessInfo.otp?(start_supervised!({Agent, fn -> :ok end}))
    refute ProcessInfo.otp?(idle_process())
  end

  describe "status/2" do
    test "reads an OTP process's state, redacted" do
      agent = start_supervised!({Agent, fn -> %{name: "Ada", password: "hunter2"} end})

      assert {:ok, %{module: ":gen_server", sys_state: ":running", state: state}} =
               ProcessInfo.status(agent, 1000)

      assert state =~ "Ada"
      assert state =~ "[REDACTED]"
      refute state =~ "hunter2"
    end

    test "never sends a system message to a plain process" do
      pid = idle_process()

      assert ProcessInfo.status(pid, 1000) == {:error, :not_otp}
      assert Process.info(pid, :message_queue_len) == {:message_queue_len, 0}
    end

    test "never sends a system message to a Task: it would never answer" do
      supervisor = start_supervised!(Task.Supervisor)
      test = self()

      task =
        Task.Supervisor.async(supervisor, fn ->
          send(test, :ready)
          receive(do: (:stop -> :ok))
        end)

      assert_receive :ready
      on_exit(fn -> send(task.pid, :stop) end)

      assert ProcessInfo.otp?(task.pid)
      assert ProcessInfo.status(task.pid, 1000) == {:error, :busy}
      assert Process.info(task.pid, :message_queue_len) == {:message_queue_len, 0}
    end

    test "never sends a system message to a Task blocked in a call" do
      test = self()
      busy = start_supervised!({Agent, fn -> :ok end}, id: :busy)

      Agent.cast(busy, fn state ->
        send(test, :busy)
        receive(do: (:release -> state))
      end)

      assert_receive :busy
      supervisor = start_supervised!(Task.Supervisor)
      task = Task.Supervisor.async(supervisor, fn -> Agent.get(busy, & &1, :infinity) end)
      wait_until(fn -> waiting_in_call?(task.pid) end)

      assert ProcessInfo.status(task.pid, 1000) == {:error, :busy}
      assert Process.info(task.pid, :message_queue_len) == {:message_queue_len, 0}

      send(busy, :release)
      assert Task.await(task) == :ok
    end

    test "a hibernated server answers" do
      agent =
        start_supervised!(%{
          id: :hibernating,
          start: {Agent, :start_link, [fn -> :ok end, [hibernate_after: 0]]}
        })

      :ok = Agent.get(agent, & &1)
      wait_until(fn -> hibernated?(agent) end)

      assert {:ok, %{sys_state: ":running"}} = ProcessInfo.status(agent, 1000)
    end

    test "a server busy in a callback is refused, a dead one is dead" do
      agent = start_supervised!({Agent, fn -> :ok end})
      test = self()

      Agent.cast(agent, fn state ->
        send(test, :busy)
        receive(do: (:release -> state))
      end)

      assert_receive :busy

      assert ProcessInfo.status(agent, 50) == {:error, :busy}

      send(agent, :release)
      _ = Agent.get(agent, & &1)
      stop_supervised!(Agent)
      assert ProcessInfo.status(agent, 50) == {:error, :dead}
    end
  end

  # A call blocks right after it is sent: no message tells when.
  defp waiting_in_call?(pid),
    do: Process.info(pid, :current_function) == {:current_function, {:gen, :do_call, 4}}

  # A server hibernates right after it replies: no message tells when. OTP 27
  # reports :gen_server.loop_hibernate/4, older ones :erlang.hibernate/3.
  defp hibernated?(pid) do
    case Process.info(pid, :current_function) do
      {:current_function, {:erlang, :hibernate, 3}} -> true
      {:current_function, {:gen_server, :loop_hibernate, _arity}} -> true
      _other -> false
    end
  end
end
