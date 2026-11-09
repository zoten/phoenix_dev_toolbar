defmodule PhoenixDevToolbar.ProcessTop do
  @moduledoc false
  # The processes with the most memory, reductions or queued messages (ADR 11):
  # the System tab's "top". A sweep of every process with process_info/2 only
  # (no call, no message to any of them), refused above a process count. Runs in
  # the panel's start_async/3 task: the reductions sort waits between its two
  # sweeps there, never in the panel process.

  alias PhoenixDevToolbar.ProcessInfo

  @sorts %{"memory" => :memory, "reductions" => :reductions, "queue" => :queue}
  @keys [:memory, :message_queue_len, :reductions]
  @count 50
  @max_processes 100_000
  @interval_ms 500

  @type by :: :memory | :reductions | :queue

  @type row :: %{
          pid: pid(),
          name: String.t(),
          memory: non_neg_integer(),
          queue: non_neg_integer(),
          reductions_per_second: non_neg_integer() | nil,
          toolbar?: boolean()
        }

  @doc "The sort a client string names, or :error (never an atom from input)."
  @spec sort(String.t()) :: {:ok, by()} | :error
  def sort(name), do: Map.fetch(@sorts, name)

  @doc """
  The #{@count} processes with the most `by`. Options: `max_processes:`
  (#{@max_processes}), `interval_ms:` (#{@interval_ms}, the reductions window).
  """
  @spec top(by(), keyword()) ::
          {:ok, [row()]} | {:error, {:too_many, non_neg_integer()}}
  def top(by, opts \\ []) when by in [:memory, :reductions, :queue] do
    # The count first: a node too big to sweep is not even listed.
    count = :erlang.system_info(:process_count)

    case count > Keyword.get(opts, :max_processes, @max_processes) do
      true ->
        {:error, {:too_many, count}}

      false ->
        {:ok, read(by, Process.list(), max(Keyword.get(opts, :interval_ms, @interval_ms), 1))}
    end
  end

  # The first sweep keeps only each pid's reductions across the wait.
  defp read(:reductions, pids, interval_ms) do
    before = Map.new(sweep(pids), fn {pid, _memory, _queue, reductions} -> {pid, reductions} end)
    Process.sleep(interval_ms)

    pids
    |> sweep()
    |> Enum.flat_map(&rate(&1, before, interval_ms))
    |> keep(& &1.reductions_per_second)
  end

  defp read(:memory, pids, _interval_ms),
    do: pids |> sweep() |> Enum.map(&row(&1, nil)) |> keep(& &1.memory)

  defp read(:queue, pids, _interval_ms),
    do: pids |> sweep() |> Enum.map(&row(&1, nil)) |> keep(& &1.queue)

  # Flat tuples, the least a sweep can hold. Exited processes give nil: skipped,
  # and so is the sweeping task itself (it would top the reductions).
  # A read of a process busy on another scheduler waits for it (a signal since
  # OTP 21): in this task, never in the panel or a host process.
  defp sweep(pids) do
    me = self()

    for pid <- pids,
        pid != me,
        [memory: memory, message_queue_len: queue, reductions: reductions] <-
          [Process.info(pid, @keys)],
        do: {pid, memory, queue, reductions}
  end

  # A pid reused within the window could go backwards: never below zero.
  defp rate({pid, _memory, _queue, reductions} = read, before, interval_ms) do
    case Map.fetch(before, pid) do
      {:ok, earlier} -> [row(read, max(div((reductions - earlier) * 1000, interval_ms), 0))]
      :error -> []
    end
  end

  defp row({pid, memory, queue, _reductions}, rate),
    do: %{pid: pid, memory: memory, queue: queue, reductions_per_second: rate}

  # Only the first are named: naming reads each process's dictionary.
  defp keep(rows, value) do
    rows
    |> Enum.sort_by(value, :desc)
    |> Enum.take(@count)
    |> Enum.map(&name/1)
  end

  defp name(%{pid: pid} = row) do
    name =
      case ProcessInfo.about(pid) do
        %{name: name} when is_binary(name) -> name
        %{initial_call: call} -> call
        nil -> "exited"
      end

    Map.merge(row, %{name: name, toolbar?: String.starts_with?(name, "PhoenixDevToolbar.")})
  end
end
