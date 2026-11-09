defmodule PhoenixDevToolbar.ProcessTree do
  @moduledoc false
  # Supervision and application trees for the System tab (ADR 11). These are
  # calls into host processes (a supervisor, the application controller,
  # application masters): each one has a timeout, or runs in a task that is
  # killed when it does not answer in time. Call them from the panel's
  # start_async/3 tasks, never from the panel process itself.
  #
  # Only real supervisors are asked for their children: a GenServer without a
  # `:which_children` clause would crash on the request. `$initial_call` tells
  # them apart (`:supervisor`, PartitionSupervisor, Registry partitions, and
  # DynamicSupervisor all answer both requests; `:supervisor_bridge` does not
  # match). A supervisor still in init, hibernated or busy only delays the
  # answer: the call times out and its late reply is dropped (an alias call).

  alias PhoenixDevToolbar.ProcessInfo
  alias PhoenixDevToolbar.Truncate

  # Children listed at most: above, counts only (the list copies every child).
  @max_children 200
  @max_apps 100
  @elixir_apps [:elixir, :logger, :eex, :iex, :mix, :ex_unit]

  @type child :: %{
          id: String.t(),
          pid: pid() | :restarting | :undefined,
          type: :worker | :supervisor,
          modules: String.t()
        }

  @type counts :: %{
          specs: non_neg_integer(),
          active: non_neg_integer(),
          supervisors: non_neg_integer(),
          workers: non_neg_integer()
        }

  @type app :: %{
          name: atom(),
          description: String.t(),
          version: String.t(),
          group: :host | :elixir | :otp,
          supervisor: pid() | nil
        }

  @doc "The most children listed; above it only the counts are read."
  @spec max_children() :: pos_integer()
  def max_children, do: @max_children

  @doc """
  Whether `pid` is a supervisor (`Supervisor`, `:supervisor`, `PartitionSupervisor`:
  `$initial_call` `{:supervisor, module, 1}`; `DynamicSupervisor`, `Task.Supervisor`:
  `{DynamicSupervisor, :init, 1}`). False on an OTP before 26.2 (no single
  dictionary key reads).
  """
  @spec supervisor?(pid()) :: boolean()
  def supervisor?(pid) when is_pid(pid),
    do: ProcessInfo.module(pid) in [:supervisor, DynamicSupervisor]

  @doc """
  A supervisor's child counts and, up to #{@max_children} children, the children
  (`:too_many` above). Waits at most `timeout` per call (two calls).
  """
  @spec children(pid(), timeout()) ::
          {:ok, counts(), [child()] | :too_many}
          | {:error, :not_supervisor | :timeout | :dead}
  def children(pid, timeout) when is_pid(pid) do
    case supervisor?(pid) do
      true -> read_children(pid, timeout)
      false -> {:error, :not_supervisor}
    end
  end

  # The requests :supervisor.which_children/1 and count_children/1 send, with a
  # timeout instead of :infinity (DynamicSupervisor answers the same ones).
  defp read_children(pid, timeout) do
    counts = pid |> GenServer.call(:count_children, timeout) |> Map.new()

    # A simple_one_for_one supervisor has one spec and any number of children.
    case max(Map.get(counts, :specs, 0), Map.get(counts, :active, 0)) do
      many when many > @max_children ->
        {:ok, counts, :too_many}

      _few ->
        children = pid |> GenServer.call(:which_children, timeout) |> Enum.map(&child/1)
        {:ok, counts, children}
    end
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :dead}
  end

  defp child({id, pid, type, modules}) do
    %{
      id: Truncate.inspect_value(id, limit: 5, printable_limit: 80),
      pid: pid,
      type: type,
      modules: modules(modules)
    }
  end

  defp modules(:dynamic), do: "dynamic"
  defp modules(modules) when is_list(modules), do: Enum.map_join(modules, ", ", &inspect/1)
  defp modules(_other), do: ""

  @doc """
  The started applications, at most #{@max_apps}: the host's and its deps' first,
  then Elixir's, then OTP's, each with its top supervisor when it has one. The
  application master answers `get_child` without a timeout: each one is asked in
  its own task, and the ones still waiting after `timeout` are killed.
  """
  @spec applications(timeout()) :: {:ok, [app()]} | {:error, :timeout | :unavailable}
  def applications(timeout) do
    started = timeout |> Application.started_applications() |> Enum.take(@max_apps)

    tasks =
      Enum.map(started, fn {name, _desc, _vsn} -> Task.async(fn -> top_supervisor(name) end) end)

    supervisors = tasks |> Task.yield_many(timeout) |> Enum.map(&yielded/1)

    apps =
      started
      |> Enum.zip(supervisors)
      |> Enum.map(fn {{name, description, version}, supervisor} ->
        %{
          name: name,
          description: to_string(description),
          version: to_string(version),
          group: group(name),
          supervisor: supervisor
        }
      end)
      |> Enum.sort_by(&{group_order(&1.group), &1.name})

    {:ok, apps}
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :unavailable}
  end

  defp yielded({_task, {:ok, supervisor}}), do: supervisor

  defp yielded({task, _late_or_exited}) do
    _ = Task.shutdown(task, :brutal_kill)
    nil
  end

  # An ETS read, then a request to the application master (no timeout: in a task).
  defp top_supervisor(name) do
    with master when is_pid(master) <- :application_controller.get_master(name),
         {supervisor, _module} when is_pid(supervisor) <- :application_master.get_child(master) do
      supervisor
    else
      _none -> nil
    end
  end

  defp group(name) when name in @elixir_apps, do: :elixir

  defp group(name) do
    case :code.lib_dir(name) do
      dir when is_list(dir) -> otp_or_host(dir)
      {:error, _reason} -> :host
    end
  end

  defp otp_or_host(dir) do
    case List.starts_with?(dir, :code.root_dir()) do
      true -> :otp
      false -> :host
    end
  end

  defp group_order(:host), do: 0
  defp group_order(:elixir), do: 1
  defp group_order(:otp), do: 2
end
