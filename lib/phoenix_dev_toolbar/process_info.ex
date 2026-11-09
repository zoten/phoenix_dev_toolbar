defmodule PhoenixDevToolbar.ProcessInfo do
  @moduledoc false
  # Reads a host process for the Process and System tabs (ADR 09, ADR 11), with
  # `Process.info/2` and explicit key lists. The read is a signal the target
  # answers: a target busy in a long NIF delays the panel, never the reverse.
  # It never reads `:messages`, `:binary` or the whole `:dictionary`, which copy
  # unbounded data (the dictionary holds assigns sized terms); only
  # `$initial_call`, `$callers` and `$ancestors` are read, one key at a time.
  # Every read of a dead process is nil, [] or :dead, never a raise. The one
  # exception to "read only" is status/2 (`:sys`), on demand.

  alias PhoenixDevToolbar.Truncate

  @max_relations 50
  # Ancestors and stack frames shown at most.
  @max_ancestors 20
  @max_frames 20

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
          toolbar?: boolean(),
          link?: boolean(),
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

  @doc """
  Garbage collects `pid` (a full sweep) and returns its memory before and after,
  or :dead. Runs in the caller: call it from a task.
  """
  @spec collect(pid()) :: {:ok, non_neg_integer(), non_neg_integer()} | :dead
  def collect(pid) when is_pid(pid) do
    with {:memory, before} <- Process.info(pid, :memory),
         true <- :erlang.garbage_collect(pid),
         {:memory, after_gc} <- Process.info(pid, :memory) do
      {:ok, before, after_gc}
    else
      _dead -> :dead
    end
  end

  @doc """
  The module a process was started for, from its `$initial_call` (a LiveView's
  is `{View, :mount, 3}`), or nil.
  """
  @spec module(pid()) :: module() | nil
  def module(pid) when is_pid(pid) and node(pid) == node() do
    case dictionary(pid, :"$initial_call") do
      {module, _fun, _arity} when is_atom(module) -> module
      _missing -> nil
    end
  end

  def module(_pid), do: nil

  @doc "Reductions per second between two samples of one process."
  @spec reductions_per_second(sample(), sample()) :: non_neg_integer()
  def reductions_per_second(%{at: t0, reductions: r0}, %{at: t1, reductions: r1}) when t1 > t0,
    do: max(div((r1 - r0) * 1000, t1 - t0), 0)

  def reductions_per_second(_previous, _sample), do: 0

  @type about :: %{
          initial_call: String.t(),
          name: String.t() | nil,
          trap_exit: boolean(),
          otp?: boolean()
        }

  @type ancestor :: %{id: String.t(), name: String.t(), pid: pid() | nil}

  @type status :: %{module: String.t(), sys_state: String.t(), state: String.t()}

  @doc """
  What the process is: its starting call, registered name, trap_exit, and
  whether it was started through `proc_lib` (`otp?/1`).
  """
  @spec about(pid()) :: about() | nil
  def about(pid) when is_pid(pid) do
    case Process.info(pid, [:initial_call, :registered_name, :trap_exit, :current_function]) do
      nil ->
        nil

      info ->
        %{
          initial_call: initial_call(pid, info[:initial_call], info[:current_function]),
          name: registered(info[:registered_name]),
          trap_exit: info[:trap_exit],
          otp?: otp?(pid)
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

  @doc """
  Who started the process, nearest first: its `$ancestors` (set by `proc_lib`,
  registered names resolved to their pid), else its `:parent` (OTP 25+). At
  most #{@max_ancestors}. `pid` is nil for a name no longer registered.
  """
  @spec ancestors(pid()) :: [ancestor()]
  def ancestors(pid) when is_pid(pid) and node(pid) == node() do
    case dictionary(pid, :"$ancestors") do
      [_ | _] = ancestors -> ancestors |> Enum.take(@max_ancestors) |> Enum.map(&ancestor/1)
      _missing -> parent(pid)
    end
  end

  def ancestors(pid) when is_pid(pid), do: []

  defp ancestor(pid) when is_pid(pid), do: %{id: inspect(pid), name: name(pid), pid: pid}

  # A registered name: shown by name, linked by its pid while it is registered.
  defp ancestor(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> %{id: inspect(pid), name: inspect(name), pid: pid}
      nil -> %{id: inspect(name), name: "not registered anymore", pid: nil}
    end
  end

  defp ancestor(other), do: %{id: inspect(other, limit: 5), name: "", pid: nil}

  # `:parent` needs OTP 25: older ones raise on the unknown item.
  defp parent(pid) do
    case Process.info(pid, :parent) do
      {:parent, parent} when is_pid(parent) -> [ancestor(parent)]
      _none -> []
    end
  rescue
    ArgumentError -> []
  end

  @doc """
  Where the process is now: its current stacktrace, formatted. As deep as the
  VM's `backtrace_depth` (8 by default), capped at #{@max_frames}. Toolbar frames
  are kept: here they are the truth.
  """
  @spec stacktrace(pid()) :: [String.t()]
  def stacktrace(pid) when is_pid(pid) and node(pid) == node() do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, frames} ->
        frames |> Enum.take(@max_frames) |> Enum.map(&Exception.format_stacktrace_entry/1)

      nil ->
        []
    end
  end

  def stacktrace(pid) when is_pid(pid), do: []

  @doc """
  Whether the process was started through `proc_lib` (GenServer, Agent, Task,
  supervisors...): its dictionary holds `$initial_call` and `$ancestors`. Not all
  of them answer system messages: a Task does not (see `status/2`). False on an
  OTP before 26.2, which cannot read single dictionary keys.
  """
  @spec otp?(pid()) :: boolean()
  def otp?(pid) when is_pid(pid) and node(pid) == node() do
    match?({_m, _f, _a}, dictionary(pid, :"$initial_call")) and
      is_list(dictionary(pid, :"$ancestors"))
  end

  def otp?(pid) when is_pid(pid), do: false

  @doc """
  The process's state through `:sys.get_status/2` (so its own `format_status`
  applies): its callback module, its sys status (`:running`, `:suspended`) and
  its state, redacted and bounded like assigns. The process dictionary in the
  status is left out. Runs code in the target: call it on demand from a task,
  never polled.

  Only a process waiting in a `gen` behaviour's loop (gen_server, gen_statem,
  gen_event, supervisors, LiveViews), or hibernated, is asked. Anything else is
  refused before a message is sent: a Task or a plain process never answers,
  and the system message would stay in its mailbox for good. A server busy in a
  callback is refused too (`:busy`): try again.
  """
  @spec status(pid(), timeout()) ::
          {:ok, status()} | {:error, :not_otp | :busy | :timeout | :dead | :failed}
  def status(pid, timeout) when is_pid(pid) and node(pid) == node() do
    case answers_sys(pid) do
      :yes -> get_status(pid, timeout)
      other -> {:error, other}
    end
  end

  def status(pid, _timeout) when is_pid(pid), do: {:error, :not_otp}

  @sys_loops [:gen_server, :gen_statem, :gen_event, :gen, :sys]

  # Whether a system message sent now gets an answer: the process waits in a
  # `gen` loop (or in `:sys`, already answering one), or hibernates (a server
  # hibernates in :erlang.hibernate/3; only proc_lib processes are considered).
  defp answers_sys(pid) do
    case {otp?(pid), Process.info(pid, :current_function)} do
      {_otp?, nil} -> :dead
      {false, _function} -> :not_otp
      {true, {:current_function, {module, _f, _a}}} when module in @sys_loops -> :yes
      {true, {:current_function, {:erlang, :hibernate, 3}}} -> :yes
      {true, _elsewhere} -> :busy
    end
  end

  defp get_status(pid, timeout) do
    {:ok, pid |> :sys.get_status(timeout) |> present()}
  rescue
    _error -> {:error, :failed}
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> {:error, :dead}
    :exit, _reason -> {:error, :failed}
  end

  # `{:status, pid, {:module, module}, [pdict, sys_state, parent, debug, misc]}`.
  # The state is redacted on its own: redaction is depth bounded, and inside the
  # status tuple it would sit too deep to reach.
  defp present({:status, _pid, {:module, module}, [_pdict, sys_state, _parent, _debug, misc]}),
    do: %{module: inspect(module), sys_state: inspect(sys_state), state: state(misc)}

  defp present(other), do: %{module: "unknown", sys_state: "unknown", state: state(other)}

  # gen_server, gen_statem, supervisors and their kin put the state under
  # `{:data, [{~c"State", state}]}` in `misc`. A `format_status/2` may give its own
  # `{:data, [{label, value}]}` entries instead (a LiveView lists its view, parent,
  # transport and topic): those are shown one per line, each value redacted on its
  # own. Any other shape is not shown: it could hold secrets deeper than
  # redaction reaches.
  @standard_labels ["Status", "Parent", "Logged events"]

  defp state(misc) do
    entries = data_entries(misc)

    case List.keyfind(entries, "State", 0) do
      {"State", state} -> state |> Truncate.redact() |> Truncate.inspect_value()
      nil -> custom(Enum.reject(entries, fn {label, _value} -> label in @standard_labels end))
    end
  end

  defp custom([]), do: "(no state in this process's status: not shown)"

  defp custom(entries) do
    entries
    |> Truncate.redact()
    |> Enum.map_join("\n", fn {label, value} -> "#{label}: #{Truncate.inspect_value(value)}" end)
  end

  defp data_entries(misc) do
    for {:data, entries} when is_list(entries) <- List.wrap(misc),
        {label, value} <- entries,
        is_list(label) or is_binary(label),
        do: {label_string(label), value}
  end

  defp label_string(label) when is_binary(label), do: label

  defp label_string(label) do
    case List.to_string(label) do
      string when is_binary(string) -> string
    end
  rescue
    ArgumentError -> "?"
  end

  @doc """
  Whether `pid` is one of the toolbar's own processes: its registered name or
  entry point is under `PhoenixDevToolbar.` (the tag ADR 09 shows, the protected
  set of ADR 10). Another node's pid never is.
  """
  @spec toolbar?(pid()) :: boolean()
  def toolbar?(pid) when is_pid(pid) and node(pid) == node(), do: toolbar_name?(name(pid))
  def toolbar?(pid) when is_pid(pid), do: false

  defp toolbar_name?(name), do: String.starts_with?(name, "PhoenixDevToolbar.")

  defp take(list) when is_list(list) do
    {Enum.take(list, @max_relations), max(length(list) - @max_relations, 0)}
  end

  defp take(_other), do: {[], 0}

  defp relation({:process, target}, owner), do: relation(target, owner)

  defp relation(pid, owner) when is_pid(pid) do
    name = name(pid)

    %{
      id: inspect(pid),
      kind: :process,
      name: name,
      child?: child?(pid, owner),
      toolbar?: toolbar_name?(name),
      link?: node(pid) == node()
    }
  end

  defp relation({:port, port}, owner), do: relation(port, owner)

  defp relation(port, _owner) when is_port(port),
    do: %{
      id: inspect(port),
      kind: :port,
      name: port_name(port),
      child?: false,
      toolbar?: false,
      link?: false
    }

  # A monitor by name ({name, node}) or a NIF resource.
  defp relation({name, node} = other, _owner) when is_atom(name) and is_atom(node),
    do: %{
      id: inspect(other),
      kind: :other,
      name: inspect(name),
      child?: false,
      toolbar?: false,
      link?: false
    }

  defp relation(other, _owner),
    do: %{
      id: inspect(other, limit: 5),
      kind: :other,
      name: "",
      child?: false,
      toolbar?: false,
      link?: false
    }

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
