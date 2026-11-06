defmodule PhoenixDevToolbar.ProcessInfoTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.ProcessInfo

  # A process that links a Task child, monitors another process, and waits.
  defp subject do
    test = self()

    pid =
      spawn(fn ->
        child = Task.async(fn -> receive(do: (:stop -> :ok)) end)
        stranger = spawn(fn -> receive(do: (:stop -> :ok)) end)
        Process.monitor(stranger)
        send(test, {:ready, child.pid, stranger})
        receive(do: (:stop -> :ok))
      end)

    assert_receive {:ready, child, stranger}

    on_exit(fn ->
      for p <- [pid, child, stranger], do: send(p, :stop)
    end)

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
    assert %{kind: :process, child?: true} = Enum.find(links, &(&1.id == inspect(child)))
    assert %{child?: true} = Enum.find(monitors, &(&1.id == inspect(child)))
    assert %{child?: false, name: name} = Enum.find(monitors, &(&1.id == inspect(stranger)))
    assert is_binary(name) and name != ""
  end

  test "a proc_lib process's entry point is read from $initial_call" do
    {pid, _child, _stranger} = subject()
    assert %{initial_call: initial_call, trap_exit: false} = ProcessInfo.about(pid)
    assert initial_call == ":erlang.apply/2"

    agent = start_supervised!({Agent, fn -> :state end})
    {:initial_call, {:proc_lib, :init_p, _arity}} = Process.info(agent, :initial_call)
    assert ProcessInfo.about(agent).initial_call =~ "in PhoenixDevToolbar.ProcessInfoTest"
  end

  test "relations are capped at 50 of each, the rest counted" do
    pid = spawn(fn -> receive(do: (:stop -> :ok)) end)
    others = for _n <- 1..60, do: spawn(fn -> receive(do: (:stop -> :ok)) end)
    for other <- others, do: send(pid, {:noop, other})

    linker =
      spawn(fn ->
        for other <- others, do: Process.link(other)
        receive(do: (:stop -> :ok))
      end)

    wait_links(linker, 60)

    assert %{links: links, more: %{links: 10}} = ProcessInfo.relations(linker)
    assert length(links) == 50

    for p <- [pid, linker | others], do: Process.exit(p, :kill)
  end

  test "a dead process reads as dead, never raises" do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert ProcessInfo.sample(pid) == :dead
    assert ProcessInfo.about(pid) == nil
    assert ProcessInfo.relations(pid) == nil
  end

  defp wait_links(pid, count) do
    case Process.info(pid, :links) do
      {:links, links} when length(links) >= count -> :ok
      _not_yet -> wait_links(pid, count)
    end
  end
end
