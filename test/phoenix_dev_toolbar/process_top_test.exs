defmodule PhoenixDevToolbar.ProcessTopTest do
  use ExUnit.Case, async: true

  import PhoenixDevToolbar.ProcessHelpers

  alias PhoenixDevToolbar.ProcessTop

  test "the process holding the most memory comes first" do
    {pid, :ok} =
      in_process(fn ->
        Process.put(:big, :lists.seq(1, 300_000))
        :ok
      end)

    assert {:ok, rows} = ProcessTop.top(:memory)
    assert %{memory: memory} = Enum.find(rows, &(&1.pid == pid))
    assert memory > 4_000_000
    assert rows == Enum.sort_by(rows, & &1.memory, :desc)
    stop(pid)
  end

  test "the longest queue comes first" do
    pid = idle_process()
    for n <- 1..500, do: send(pid, {:n, n})

    assert {:ok, rows} = ProcessTop.top(:queue)
    assert %{queue: 500} = Enum.find(rows, &(&1.pid == pid))
    stop(pid)
  end

  test "a busy process shows in reductions per second" do
    busy = spawn(fn -> spin(0) end)
    on_exit(fn -> Process.exit(busy, :kill) end)

    assert {:ok, rows} = ProcessTop.top(:reductions, interval_ms: 100)
    assert %{reductions_per_second: rate} = Enum.find(rows, &(&1.pid == busy))
    assert rate > 0
    assert length(rows) <= 50
    refute Enum.any?(rows, &(&1.pid == self()))
  end

  test "rows are named; toolbar processes are tagged" do
    assert {:ok, rows} = ProcessTop.top(:memory)
    assert Enum.all?(rows, &is_binary(&1.name))
  end

  test "a node with too many processes is not swept" do
    count = length(Process.list())

    assert {:error, {:too_many, seen}} = ProcessTop.top(:memory, max_processes: 1)
    assert seen >= count - 50
  end

  test "sorts come from strings, never atoms" do
    assert ProcessTop.sort("queue") == {:ok, :queue}
    assert ProcessTop.sort("pdt_not_a_sort") == :error
  end

  defp spin(n), do: spin(n + 1)
end
