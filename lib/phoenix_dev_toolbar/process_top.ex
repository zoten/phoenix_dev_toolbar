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
    pids = Process.list()
    count = length(pids)

    case count > Keyword.get(opts, :max_processes, @max_processes) do
      true -> {:error, {:too_many, count}}
      false -> {:ok, read(by, pids, Keyword.get(opts, :interval_ms, @interval_ms))}
    end
  end

  defp read(:reductions, pids, interval_ms) do
    before = Map.new(sweep(pids), fn {pid, info} -> {pid, info.reductions} end)
    Process.sleep(interval_ms)

    pids
    |> sweep()
    |> Enum.flat_map(fn {pid, info} -> rate(pid, info, before, interval_ms) end)
    |> keep(& &1.reductions_per_second)
  end

  defp read(:memory, pids, _interval_ms),
    do: pids |> sweep() |> Enum.map(&row/1) |> keep(& &1.memory)

  defp read(:queue, pids, _interval_ms),
    do: pids |> sweep() |> Enum.map(&row/1) |> keep(& &1.queue)

  # Exited processes give nil: skipped. The panel's own process is read like any.
  defp sweep(pids) do
    for pid <- pids, info = Process.info(pid, @keys), info != nil do
      {pid,
       %{
         memory: info[:memory],
         queue: info[:message_queue_len],
         reductions: info[:reductions]
       }}
    end
  end

  defp rate(pid, info, before, interval_ms) do
    case Map.fetch(before, pid) do
      {:ok, earlier} ->
        per_second = div((info.reductions - earlier) * 1000, max(interval_ms, 1))
        [%{row({pid, info}) | reductions_per_second: per_second}]

      :error ->
        []
    end
  end

  defp row({pid, info}),
    do: %{pid: pid, memory: info.memory, queue: info.queue, reductions_per_second: nil}

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
