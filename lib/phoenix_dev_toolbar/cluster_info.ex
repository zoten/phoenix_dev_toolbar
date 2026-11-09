defmodule PhoenixDevToolbar.ClusterInfo do
  @moduledoc false
  # The node and its connected nodes for the Cluster tab (ADR 12). Each node is
  # read in its own task with a deadline, through `:erpc` with stdlib functions
  # only (the other node may not have this library). Call it from the panel's
  # start_async/3 task, never from the panel process.

  @max_nodes 50

  @type stats :: %{
          rtt_us: non_neg_integer(),
          processes: non_neg_integer(),
          memory: non_neg_integer(),
          otp: String.t(),
          uptime_s: non_neg_integer()
        }

  @type node_info :: %{
          name: node(),
          kind: :self | :visible | :hidden,
          stats: stats() | :timeout | :error
        }

  @type t :: %{alive?: boolean(), node: node(), nodes: [node_info()], more: non_neg_integer()}

  @doc "This node and up to #{@max_nodes} connected nodes, each read within `timeout`."
  @spec read(timeout()) :: t()
  def read(timeout) do
    hidden = Node.list(:hidden)
    connected = Node.list(:connected)
    shown = Enum.take(connected, @max_nodes)

    targets = [{node(), :self} | Enum.map(shown, &{&1, kind(&1, hidden)})]

    nodes =
      targets
      |> Enum.map(fn {name, _kind} -> Task.async(fn -> stats(name, timeout) end) end)
      |> Task.yield_many(timeout + 100)
      |> Enum.zip(targets)
      |> Enum.map(fn {{task, result}, {name, kind}} ->
        %{name: name, kind: kind, stats: yielded(task, result)}
      end)

    %{alive?: Node.alive?(), node: node(), nodes: nodes, more: length(connected) - length(shown)}
  end

  defp kind(name, hidden) do
    case name in hidden do
      true -> :hidden
      false -> :visible
    end
  end

  defp yielded(_task, {:ok, stats}), do: stats

  defp yielded(task, _late_or_exited) do
    _ = Task.shutdown(task, :brutal_kill)
    :timeout
  end

  # The first call's time is the round trip; the rest share what is left.
  defp stats(name, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    started = System.monotonic_time(:microsecond)
    processes = call(name, :erlang, :system_info, [:process_count], deadline)
    rtt = System.monotonic_time(:microsecond) - started

    %{
      rtt_us: rtt,
      processes: processes,
      memory: call(name, :erlang, :memory, [:total], deadline),
      otp: name |> call(:erlang, :system_info, [:otp_release], deadline) |> to_string(),
      uptime_s:
        name |> call(:erlang, :statistics, [:wall_clock], deadline) |> elem(0) |> div(1000)
    }
  catch
    :error, {:erpc, :timeout} -> :timeout
    _kind, _reason -> :error
  end

  defp call(name, module, fun, args, _deadline) when name == node(), do: apply(module, fun, args)

  defp call(name, module, fun, args, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 1)
    :erpc.call(name, module, fun, args, left)
  end
end
