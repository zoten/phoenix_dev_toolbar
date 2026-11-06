defmodule PhoenixDevToolbar.ProcessInfoTest do
  use ExUnit.Case, async: true

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

  test "a dead process reads as dead, never raises" do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    # :noproc when it exited before the monitor was set.
    assert_receive {:DOWN, ^ref, :process, ^pid, _normal_or_noproc}

    assert ProcessInfo.sample(pid) == :dead
    assert ProcessInfo.about(pid) == nil
    assert ProcessInfo.relations(pid) == nil
  end
end
