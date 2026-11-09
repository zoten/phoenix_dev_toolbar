defmodule PhoenixDevToolbar.EvalRunner do
  @moduledoc false
  # What the Eval tab runs (ADR 12): a fixed list of read queries, picked by id,
  # and, only when the host allowed it, code typed in the panel. Code runs in a
  # process of its own (its group leader a StringIO, so what it prints is kept),
  # killed when it outlives the timeout; the caller (the panel's start_async/3
  # task) only waits. Results and output are truncated.

  require Logger

  alias PhoenixDevToolbar.Truncate

  @max_code_bytes 10_000
  @output_bytes 8_000

  @type run :: %{
          result: String.t() | nil,
          error: String.t() | nil,
          output: String.t(),
          ms: non_neg_integer()
        }

  @queries [
    {"memory", "Memory by kind (:erlang.memory/0)"},
    {"system", "System: OTP, Elixir, schedulers, uptime"},
    {"run_queue", "Run queues (:erlang.statistics(:total_run_queue_lengths))"},
    {"applications", "Started applications"},
    {"ets", "ETS tables, the 20 largest by memory"},
    {"counts", "Process, port and ETS table counts and limits"},
    {"registered", "Registered process names"}
  ]

  @doc "The read queries: `{id, label}`."
  @spec queries() :: [{String.t(), String.t()}]
  def queries, do: @queries

  @doc "The most code a run takes, in bytes."
  @spec max_code_bytes() :: pos_integer()
  def max_code_bytes, do: @max_code_bytes

  @doc "Runs the read query `id` (a client string, matched against the list)."
  @spec query(String.t()) :: {:ok, run()} | :error
  def query(id) when is_binary(id) do
    case List.keymember?(@queries, id, 0) do
      true -> {:ok, timed(fn -> %{result: inspect_result(read(id)), error: nil, output: ""} end)}
      false -> :error
    end
  end

  defp read("memory"), do: :erlang.memory()

  defp read("system") do
    %{
      otp: to_string(:erlang.system_info(:otp_release)),
      elixir: System.version(),
      schedulers_online: :erlang.system_info(:schedulers_online),
      dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers),
      uptime_s: div(elem(:erlang.statistics(:wall_clock), 0), 1000),
      node: node()
    }
  end

  defp read("run_queue"), do: :erlang.statistics(:total_run_queue_lengths)

  defp read("applications"),
    do:
      Enum.map(Application.started_applications(), fn {app, _desc, vsn} ->
        {app, to_string(vsn)}
      end)

  defp read("ets") do
    :ets.all()
    |> Enum.map(fn table -> {table, :ets.info(table, :name), :ets.info(table, :memory)} end)
    |> Enum.filter(fn {_table, _name, memory} -> is_integer(memory) end)
    |> Enum.sort_by(fn {_table, _name, memory} -> memory end, :desc)
    |> Enum.take(20)
    |> Enum.map(fn {_table, name, words} -> {name, words * :erlang.system_info(:wordsize)} end)
  end

  defp read("counts") do
    %{
      processes: {:erlang.system_info(:process_count), :erlang.system_info(:process_limit)},
      ports: {:erlang.system_info(:port_count), :erlang.system_info(:port_limit)},
      ets_tables: {:erlang.system_info(:ets_count), :erlang.system_info(:ets_limit)},
      atoms: {:erlang.system_info(:atom_count), :erlang.system_info(:atom_limit)}
    }
  end

  defp read("registered"), do: Enum.sort(Process.registered())

  @doc """
  Evaluates `code` (at most #{@max_code_bytes} bytes) in a process of its own,
  killed after `timeout_ms`. Logs its size, never its code.
  """
  @spec eval(String.t(), pos_integer()) :: {:ok, run()} | {:error, String.t()}
  def eval(code, _timeout_ms) when is_binary(code) and byte_size(code) > @max_code_bytes,
    do: {:error, "At most #{@max_code_bytes} bytes."}

  def eval(code, timeout_ms) when is_binary(code) do
    Logger.info("[phoenix_dev_toolbar] evaluating #{byte_size(code)} bytes from the Eval tab")
    {:ok, timed(fn -> run(code, timeout_ms) end)}
  end

  # The result travels in the exit reason: whatever the code does to its own
  # process (links, exits, a throw), the caller only sees a DOWN.
  defp run(code, timeout_ms) do
    {pid, ref} = spawn_monitor(fn -> exit({:pdt_eval, evaluate(code)}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:pdt_eval, run}} ->
        run

      {:DOWN, ^ref, :process, ^pid, reason} ->
        %{result: nil, error: "exited: " <> inspect_result(reason), output: ""}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        %{result: nil, error: "No result after #{timeout_ms} ms: stopped.", output: ""}
    end
  end

  defp evaluate(code) do
    {:ok, io} = StringIO.open("")
    Process.group_leader(self(), io)

    outcome =
      try do
        {value, _binding} = Code.eval_string(code, [], file: "eval tab")
        {:ok, value}
      rescue
        exception -> {:error, Exception.format(:error, exception, __STACKTRACE__)}
      catch
        kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
      end

    {_input, output} = StringIO.contents(io)
    output = Truncate.string(output, @output_bytes)

    case outcome do
      {:ok, value} ->
        %{result: inspect_result(value), error: nil, output: output}

      {:error, text} ->
        %{result: nil, error: Truncate.string(text, @output_bytes), output: output}
    end
  end

  defp inspect_result(value), do: Truncate.inspect_value(value, pretty: true, width: 80)

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    run = fun.()
    Map.put(run, :ms, System.monotonic_time(:millisecond) - started)
  end
end
