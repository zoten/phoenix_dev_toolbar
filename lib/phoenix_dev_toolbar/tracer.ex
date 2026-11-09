defmodule PhoenixDevToolbar.Tracer do
  @moduledoc false
  # Message trace for the System tab (ADR 11): what one process receives and
  # sends, through an OTP 27 trace session (the `:trace` module), so it never
  # takes the global tracer `dbg` or `recon` may be using. One trace on the node
  # at a time; it stops by itself after @max_events messages or @ttl_ms, when the
  # process exits, when the panel that asked goes away, or on stop/1. Every stop
  # destroys the session, and so does this process's own exit.
  #
  # Called only from the panel (our process), with a short timeout.

  use GenServer

  alias PhoenixDevToolbar.Truncate

  @name PhoenixDevToolbar.Tracer
  @max_events 100
  @ttl_ms 10_000
  @call_timeout 1000

  @type event :: %{
          at_ms: non_neg_integer(),
          dir: :in | :out,
          peer: pid() | String.t() | nil,
          message: String.t()
        }

  @type status :: %{
          pid: pid(),
          events: [event()],
          running?: boolean(),
          stopped: nil | :limit | :time | :exited | :stopped,
          left_ms: non_neg_integer()
        }

  @doc "Whether trace sessions exist on this OTP (27+)."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(:trace)

  @doc "The most messages a trace records."
  @spec max_events() :: pos_integer()
  def max_events, do: @max_events

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg), do: GenServer.start_link(@name, :ok, name: @name)

  @doc "Starts tracing `pid` for `owner` (the panel), replacing its previous trace."
  @spec start(pid(), pid()) :: :ok | {:error, :busy | :dead | :unavailable}
  def start(pid, owner) when is_pid(pid) and is_pid(owner), do: call({:start, pid, owner})

  @doc "Stops `owner`'s trace, keeping what it recorded."
  @spec stop(pid()) :: :ok
  def stop(owner) do
    _ = call({:stop, owner})
    :ok
  end

  @doc "`owner`'s trace: what it recorded so far, and whether it still runs."
  @spec status(pid()) :: status() | nil
  def status(owner) do
    case call({:status, owner}) do
      {:error, :unavailable} -> nil
      status -> status
    end
  end

  defp call(message) do
    GenServer.call(@name, message, @call_timeout)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  ## Server

  @impl GenServer
  def init(:ok) do
    # terminate/2 runs on a supervisor shutdown: the session is destroyed then.
    Process.flag(:trap_exit, true)
    {:ok, %{trace: nil}}
  end

  @impl GenServer
  def handle_call({:start, pid, owner}, _from, %{trace: trace} = state) do
    case {available?(), trace} do
      {false, _trace} ->
        {:reply, {:error, :unavailable}, state}

      {true, %{owner: other, running?: true}} when other != owner ->
        {:reply, {:error, :busy}, state}

      {true, _none_or_mine} ->
        do_start(clear(state), pid, owner)
    end
  end

  def handle_call({:stop, owner}, _from, %{trace: %{owner: owner}} = state),
    do: {:reply, :ok, finish(state, :stopped)}

  def handle_call({:stop, _owner}, _from, state), do: {:reply, :ok, state}

  def handle_call({:status, owner}, _from, %{trace: %{owner: owner} = trace} = state),
    do: {:reply, public(trace), state}

  def handle_call({:status, _owner}, _from, state), do: {:reply, nil, state}

  defp do_start(state, pid, owner) do
    session = trace_mod().session_create(:phoenix_dev_toolbar, self(), [])

    case trace_mod().process(session, pid, true, [:send, :receive]) do
      1 ->
        trace = %{
          pid: pid,
          owner: owner,
          session: session,
          started: System.monotonic_time(:millisecond),
          events: [],
          count: 0,
          running?: true,
          stopped: nil,
          refs: [Process.monitor(pid), Process.monitor(owner)],
          timer: Process.send_after(self(), :pdt_trace_time, @ttl_ms)
        }

        {:reply, :ok, %{state | trace: trace}}

      _none ->
        trace_mod().session_destroy(session)
        {:reply, {:error, :dead}, state}
    end
  rescue
    ArgumentError -> {:reply, {:error, :dead}, state}
  end

  @impl GenServer
  def handle_info(
        {:trace, pid, :receive, message},
        %{trace: %{pid: pid, running?: true}} = state
      ),
      do: {:noreply, record(state, :in, nil, message)}

  def handle_info(
        {:trace, pid, :send, message, to},
        %{trace: %{pid: pid, running?: true}} = state
      ),
      do: {:noreply, record(state, :out, to, message)}

  # Queued before the stop landed, or from a previous trace: dropped.
  def handle_info({:trace, _pid, _kind, _message}, state), do: {:noreply, state}
  def handle_info({:trace, _pid, _kind, _message, _to}, state), do: {:noreply, state}

  def handle_info(:pdt_trace_time, %{trace: %{running?: true}} = state),
    do: {:noreply, finish(state, :time)}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{trace: %{refs: [ref, _owner]}} = state
      ),
      do: {:noreply, finish(state, :exited)}

  # The panel went away: nobody will read the trace.
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{trace: %{refs: [_target, ref]}} = state
      ),
      do: {:noreply, clear(state)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = clear(state)
    :ok
  end

  defp record(%{trace: trace} = state, dir, to, message) do
    event = %{
      at_ms: System.monotonic_time(:millisecond) - trace.started,
      dir: dir,
      peer: peer(to),
      message: message |> Truncate.redact() |> Truncate.inspect_value()
    }

    trace = %{trace | events: [event | trace.events], count: trace.count + 1}

    case trace.count >= @max_events do
      true -> finish(%{state | trace: trace}, :limit)
      false -> %{state | trace: trace}
    end
  end

  defp peer(pid) when is_pid(pid), do: pid
  defp peer(nil), do: nil
  defp peer(other), do: Truncate.inspect_value(other, limit: 5, printable_limit: 80)

  # Stops tracing, keeps the events for the panel to read.
  defp finish(%{trace: %{running?: true} = trace} = state, why) do
    destroy(trace)
    %{state | trace: %{trace | running?: false, stopped: why}}
  end

  defp finish(state, _why), do: state

  # Stops tracing and forgets the trace.
  defp clear(%{trace: nil} = state), do: state

  defp clear(%{trace: trace} = state) do
    destroy(trace)
    %{state | trace: nil}
  end

  defp destroy(%{session: session, refs: refs, timer: timer, running?: running?}) do
    _ = Process.cancel_timer(timer)
    Enum.each(refs, &Process.demonitor(&1, [:flush]))
    destroy_session(session, running?)
  end

  defp destroy_session(session, true), do: trace_mod().session_destroy(session)
  defp destroy_session(_session, false), do: true

  defp public(trace) do
    %{
      pid: trace.pid,
      events: Enum.reverse(trace.events),
      running?: trace.running?,
      stopped: trace.stopped,
      left_ms: max(@ttl_ms - (System.monotonic_time(:millisecond) - trace.started), 0)
    }
  end

  # Through a variable: OTP 26 has no :trace module, and must compile cleanly.
  defp trace_mod, do: :trace
end
