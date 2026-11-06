defmodule PhoenixDevToolbar.ProcessInfo do
  @moduledoc false
  # Reads a host process for the Process tab (ADR 09), with `Process.info/2`
  # and explicit key lists. The read is a signal the target answers: a target
  # busy in a long NIF delays the panel, never the reverse. It never
  # reads `:messages`, `:binary` or the whole `:dictionary`, which copy
  # unbounded data (the dictionary holds assigns sized terms); only two
  # dictionary keys are read, one at a time. Every read of a dead process is
  # nil or :dead, never a raise.

  @max_relations 50

  @sample_keys [
    :memory,
    :message_queue_len,
    :reductions,
    :total_heap_size,
    :heap_size,
    :stack_size,
    :garbage_collection,
    :status,
    :current_function
  ]

  @type sample :: %{
          at: integer(),
          memory: non_neg_integer(),
          message_queue_len: non_neg_integer(),
          reductions: non_neg_integer(),
          total_heap_size: non_neg_integer(),
          heap_size: non_neg_integer(),
          stack_size: non_neg_integer(),
          minor_gcs: non_neg_integer() | nil,
          fullsweep_after: non_neg_integer() | nil,
          min_heap_size: non_neg_integer() | nil,
          status: atom(),
          current_function: String.t()
        }

  @type relation :: %{
          id: String.t(),
          kind: :process | :port | :other,
          name: String.t(),
          child?: boolean()
        }

  @type relations :: %{
          links: [relation()],
          monitors: [relation()],
          monitored_by: [relation()],
          more: %{
            links: non_neg_integer(),
            monitors: non_neg_integer(),
            monitored_by: non_neg_integer()
          }
        }

  @doc "The process's vital signs, stamped with a monotonic time in ms, or :dead."
  @spec sample(pid()) :: {:ok, sample()} | :dead
  def sample(pid) when is_pid(pid) do
    case Process.info(pid, @sample_keys) do
      nil ->
        :dead

      info ->
        gc = Keyword.get(info, :garbage_collection, [])

        {:ok,
         %{
           at: System.monotonic_time(:millisecond),
           memory: info[:memory],
           message_queue_len: info[:message_queue_len],
           reductions: info[:reductions],
           total_heap_size: info[:total_heap_size],
           heap_size: info[:heap_size],
           stack_size: info[:stack_size],
           minor_gcs: gc[:minor_gcs],
           fullsweep_after: gc[:fullsweep_after],
           min_heap_size: gc[:min_heap_size],
           status: info[:status],
           current_function: mfa(info[:current_function])
         }}
    end
  end

  @doc "Reductions per second between two samples of one process."
  @spec reductions_per_second(sample(), sample()) :: non_neg_integer()
  def reductions_per_second(%{at: t0, reductions: r0}, %{at: t1, reductions: r1}) when t1 > t0,
    do: max(div((r1 - r0) * 1000, t1 - t0), 0)

  def reductions_per_second(_previous, _sample), do: 0

  @doc "What the process is: its starting call, registered name, trap_exit."
  @spec about(pid()) ::
          %{initial_call: String.t(), name: String.t() | nil, trap_exit: boolean()} | nil
  def about(pid) when is_pid(pid) do
    case Process.info(pid, [:initial_call, :registered_name, :trap_exit, :current_function]) do
      nil ->
        nil

      info ->
        %{
          initial_call: initial_call(pid, info[:initial_call], info[:current_function]),
          name: registered(info[:registered_name]),
          trap_exit: info[:trap_exit]
        }
    end
  end

  @doc """
  Its links, monitors and monitors on it, #{@max_relations} of each at most (`more`
  counts the rest). Each related process is named, and marked as a child when
  its `$callers` holds `pid` (`Task.async`, `start_async`).
  """
  @spec relations(pid()) :: relations() | nil
  def relations(pid) when is_pid(pid) do
    case Process.info(pid, [:links, :monitors, :monitored_by]) do
      nil ->
        nil

      info ->
        {links, more_links} = take(info[:links])
        {monitors, more_monitors} = take(info[:monitors])
        {monitored_by, more_monitored_by} = take(info[:monitored_by])

        %{
          links: Enum.map(links, &relation(&1, pid)),
          monitors: Enum.map(monitors, &relation(&1, pid)),
          monitored_by: Enum.map(monitored_by, &relation(&1, pid)),
          more: %{links: more_links, monitors: more_monitors, monitored_by: more_monitored_by}
        }
    end
  end

  defp take(list) when is_list(list) do
    {Enum.take(list, @max_relations), max(length(list) - @max_relations, 0)}
  end

  defp take(_other), do: {[], 0}

  defp relation({:process, target}, owner), do: relation(target, owner)

  defp relation(pid, owner) when is_pid(pid) do
    %{id: inspect(pid), kind: :process, name: name(pid), child?: child?(pid, owner)}
  end

  defp relation({:port, port}, owner), do: relation(port, owner)

  defp relation(port, _owner) when is_port(port),
    do: %{id: inspect(port), kind: :port, name: port_name(port), child?: false}

  # A monitor by name ({name, node}) or a NIF resource.
  defp relation({name, node} = other, _owner) when is_atom(name) and is_atom(node),
    do: %{id: inspect(other), kind: :other, name: inspect(name), child?: false}

  defp relation(other, _owner),
    do: %{id: inspect(other, limit: 5), kind: :other, name: "", child?: false}

  # Process.info/2 and Port.info/2 raise on another node's pid or port: those
  # are only named by their node.
  defp name(pid) when node(pid) != node(), do: "on #{node(pid)}"

  defp name(pid) do
    case Process.info(pid, [:registered_name, :initial_call, :current_function]) do
      nil ->
        "exited"

      info ->
        registered(info[:registered_name]) ||
          initial_call(pid, info[:initial_call], info[:current_function])
    end
  end

  defp port_name(port) when node(port) != node(), do: "on #{node(port)}"

  defp port_name(port) do
    case Port.info(port, :name) do
      {:name, name} -> to_string(name)
      nil -> "closed"
    end
  end

  defp registered([]), do: nil
  defp registered(name) when is_atom(name), do: inspect(name)
  defp registered(_other), do: nil

  # GenServers and Tasks keep their real entry point in `$initial_call` (their
  # `initial_call` is proc_lib's or Task.Supervised's). A plain spawn starts in
  # :erlang.apply/2: what it runs now says more.
  defp initial_call(pid, initial_call, current_function) do
    case dictionary(pid, :"$initial_call") do
      # A supervisor's is {:supervisor, Module, 1}: Module is the useful part.
      {:supervisor, module, 1} -> inspect(module) <> " (supervisor)"
      {_m, _f, _a} = mfa -> mfa(mfa)
      _missing when initial_call == {:erlang, :apply, 2} -> mfa(current_function)
      _missing -> mfa(initial_call)
    end
  end

  defp child?(pid, _owner) when node(pid) != node(), do: false

  defp child?(pid, owner) do
    case dictionary(pid, :"$callers") do
      callers when is_list(callers) -> owner in callers
      _missing -> false
    end
  end

  # One dictionary key, never the whole dictionary: `{:dictionary, key}` needs
  # OTP 26.2. Whether this OTP has it is checked once, then cached.
  defp dictionary(pid, key) do
    case dictionary_key?() do
      true -> dictionary_key(pid, key)
      false -> nil
    end
  end

  defp dictionary_key(pid, key) do
    case :erlang.process_info(pid, {:dictionary, key}) do
      {{:dictionary, ^key}, value} -> value
      _dead -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @capability {__MODULE__, :dictionary_key?}

  defp dictionary_key? do
    case :persistent_term.get(@capability, nil) do
      nil ->
        supported? = supported?()
        :persistent_term.put(@capability, supported?)
        supported?

      supported? ->
        supported?
    end
  end

  defp supported? do
    _ = :erlang.process_info(self(), {:dictionary, :pdt_probe})
    true
  rescue
    ArgumentError -> false
  end

  defp mfa({m, f, a}) when is_atom(m) and is_atom(f) and is_integer(a),
    do: Exception.format_mfa(m, f, a)

  defp mfa(_other), do: "unknown"
end
