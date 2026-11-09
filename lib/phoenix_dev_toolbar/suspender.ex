defmodule PhoenixDevToolbar.Suspender do
  @moduledoc false
  # Suspends host processes for a while (ADR 10), and always resumes them: after
  # their TTL, when the panel that asked goes away, or on resume/1. A process
  # suspended here stays suspended only while this process lives: OTP removes the
  # suspensions a process made when it exits, so a crash of the Suspender
  # resumes everything.
  #
  # Called only from the panel (our process, never a host one), with a short
  # timeout: a Suspender restarting answers an error, never crashes the panel.

  use GenServer

  @name PhoenixDevToolbar.Suspender
  @max_suspended 10
  @min_ttl_ms 1000
  @max_ttl_ms 60_000
  @call_timeout 1000

  @type error :: :too_many | :already | :ttl | :dead | :unavailable

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg), do: GenServer.start_link(@name, :ok, name: @name)

  @doc "Suspends `pid` for `ttl_ms` on behalf of `owner` (the panel)."
  @spec suspend(pid(), pos_integer(), pid()) :: :ok | {:error, error()}
  def suspend(pid, ttl_ms, owner) when is_pid(pid) and is_pid(owner),
    do: call({:suspend, pid, ttl_ms, owner})

  @doc "Resumes `pid` if it was suspended here."
  @spec resume(pid()) :: :ok | {:error, :not_suspended | :unavailable}
  def resume(pid) when is_pid(pid), do: call({:resume, pid})

  @doc "The processes suspended here, with their monotonic deadline in ms."
  @spec suspended() :: %{pid() => integer()}
  def suspended do
    case call(:suspended) do
      %{} = suspended -> suspended
      {:error, :unavailable} -> %{}
    end
  end

  defp call(message) do
    GenServer.call(@name, message, @call_timeout)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  ## Server

  @impl GenServer
  def init(:ok), do: {:ok, %{suspended: %{}, refs: %{}}}

  @impl GenServer
  def handle_call({:suspend, pid, ttl_ms, owner}, _from, state) do
    case check(state, pid, ttl_ms) do
      :ok -> do_suspend(state, pid, ttl_ms, owner)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:resume, pid}, _from, state) do
    case Map.has_key?(state.suspended, pid) do
      true -> {:reply, :ok, release(state, pid, :resume)}
      false -> {:reply, {:error, :not_suspended}, state}
    end
  end

  def handle_call(:suspended, _from, state),
    do: {:reply, Map.new(state.suspended, fn {pid, entry} -> {pid, entry.deadline} end), state}

  defp check(state, pid, ttl_ms) do
    cond do
      Map.has_key?(state.suspended, pid) -> {:error, :already}
      map_size(state.suspended) >= @max_suspended -> {:error, :too_many}
      not (is_integer(ttl_ms) and ttl_ms in @min_ttl_ms..@max_ttl_ms) -> {:error, :ttl}
      true -> :ok
    end
  end

  # A dead pid, another node's, or this process itself: suspend_process/1 raises.
  defp do_suspend(state, pid, ttl_ms, owner) do
    true = :erlang.suspend_process(pid)
    target_ref = Process.monitor(pid)
    owner_ref = Process.monitor(owner)
    token = make_ref()
    timer = Process.send_after(self(), {:expire, pid, token}, ttl_ms)

    entry = %{
      owner: owner,
      deadline: System.monotonic_time(:millisecond) + ttl_ms,
      timer: timer,
      token: token,
      target_ref: target_ref,
      owner_ref: owner_ref
    }

    state = %{
      state
      | suspended: Map.put(state.suspended, pid, entry),
        refs:
          state.refs |> Map.put(target_ref, {:target, pid}) |> Map.put(owner_ref, {:owner, pid})
    }

    {:reply, :ok, state}
  rescue
    ArgumentError -> {:reply, {:error, :dead}, state}
  end

  @impl GenServer
  def handle_info({:expire, pid, token}, state) do
    case state.suspended do
      %{^pid => %{token: ^token}} -> {:noreply, release(state, pid, :resume)}
      _stale -> {:noreply, state}
    end
  end

  # The target exited: nothing to resume. The owner (the panel) went away: resume.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.refs, ref) do
      {:ok, {:target, pid}} -> {:noreply, release(state, pid, :forget)}
      {:ok, {:owner, pid}} -> {:noreply, release(state, pid, :resume)}
      :error -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp release(state, pid, how) do
    {entry, suspended} = Map.pop(state.suspended, pid)
    _ = Process.cancel_timer(entry.timer)
    Process.demonitor(entry.target_ref, [:flush])
    Process.demonitor(entry.owner_ref, [:flush])
    resume_process(pid, how)

    %{
      state
      | suspended: suspended,
        refs: Map.drop(state.refs, [entry.target_ref, entry.owner_ref])
    }
  end

  defp resume_process(pid, :resume) do
    :erlang.resume_process(pid)
  rescue
    ArgumentError -> false
  end

  defp resume_process(_pid, :forget), do: false
end
