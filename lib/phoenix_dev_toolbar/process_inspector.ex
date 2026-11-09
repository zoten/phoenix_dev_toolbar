defmodule PhoenixDevToolbar.ProcessInspector do
  @moduledoc false
  # The state of one inspected process in a panel (ADR 09, ADR 11), shared by
  # the Process and System tabs: functions over the panel's LiveComponent socket.
  #
  # Assigns: `selected` (the pid), `about`, `sample` (a map, or :dead), `series`
  # (sparkline points, newest first), `relations`, `timers` (one pending timer per
  # kind, with its token), and the GC state (`gc`, `gc_at`, `gc_note`, `gc_timer`).
  #
  # Each panel decides when it polls (shown and visible) and what a tick also
  # does (the Process tab refreshes its targets): it composes these steps.
  # `module` is the panel's module, for Panel.send_after/4.

  import Phoenix.Component, only: [assign: 2, assign: 3, update: 3]
  import Phoenix.LiveView, only: [start_async: 3, cancel_async: 2]

  alias Phoenix.LiveView.Socket
  alias PhoenixDevToolbar.Panel
  alias PhoenixDevToolbar.ProcessActions
  alias PhoenixDevToolbar.ProcessInfo
  alias PhoenixDevToolbar.ProcessOptions

  # At most one garbage collection per second, on the selected process only.
  @gc_every_ms 1000

  @type kind :: :sample | :relations

  @doc "The assigns of a panel that inspects nothing yet."
  @spec init(Socket.t()) :: Socket.t()
  def init(socket) do
    socket
    |> assign(selected: nil, timers: %{})
    |> assign(gc: nil, gc_at: nil, gc_note: nil, gc_timer: nil)
    |> assign(about: nil, sample: nil, relations: nil, series: empty_series())
    |> assign(confirm: nil, note: nil, action_at: nil)
  end

  @doc "A new target (nil: none): its data starts over, a running GC is cancelled."
  @spec select(Socket.t(), pid() | nil) :: Socket.t()
  def select(socket, pid) do
    socket
    |> cancel_gc()
    |> assign(
      selected: pid,
      gc: nil,
      about: nil,
      gc_note: nil,
      sample: nil,
      relations: nil,
      series: empty_series(),
      confirm: nil,
      note: nil
    )
  end

  # A collection still running for the previous target (a process stuck in a
  # NIF) would otherwise leave its task behind.
  defp cancel_gc(%{assigns: %{gc: :running}} = socket),
    do: socket |> cancel_async(:gc) |> assign(:gc, nil)

  defp cancel_gc(socket), do: socket

  ## Reads

  @doc "Reads what the target is (once per target), its vitals and its relations."
  @spec read_all(Socket.t()) :: Socket.t()
  def read_all(socket), do: socket |> read_about() |> read_sample() |> read_relations()

  @doc "What the target is: read once per target."
  @spec read_about(Socket.t()) :: Socket.t()
  def read_about(%{assigns: %{selected: pid, about: nil}} = socket) when is_pid(pid),
    do: assign(socket, :about, ProcessInfo.about(pid))

  def read_about(socket), do: socket

  @doc "One sample of the vitals, pushed onto the sparklines."
  @spec read_sample(Socket.t()) :: Socket.t()
  def read_sample(%{assigns: %{selected: pid}} = socket) when is_pid(pid) do
    case ProcessInfo.sample(pid) do
      {:ok, sample} ->
        rate = rate(socket.assigns.sample, sample)
        samples = config(socket).samples

        socket
        |> assign(:sample, Map.put(sample, :reductions_per_second, rate))
        |> update(:series, &push(&1, sample, rate, samples))

      :dead ->
        assign(socket, :sample, :dead)
    end
  end

  def read_sample(socket), do: socket

  @doc "Links, monitors and monitors on the target."
  @spec read_relations(Socket.t()) :: Socket.t()
  def read_relations(%{assigns: %{selected: pid}} = socket) when is_pid(pid),
    do: assign(socket, :relations, ProcessInfo.relations(pid))

  def read_relations(socket), do: socket

  defp rate(%{at: _at} = previous, sample),
    do: ProcessInfo.reductions_per_second(previous, sample)

  defp rate(_none, _sample), do: nil

  defp empty_series, do: %{memory: [], queue: [], reductions: []}

  # Newest first, at most `samples` points per series (reversed to render).
  defp push(series, sample, rate, samples) do
    %{
      memory: keep(series.memory, sample.memory, samples),
      queue: keep(series.queue, sample.message_queue_len, samples),
      reductions: keep(series.reductions, rate, samples)
    }
  end

  defp keep(values, nil, _samples), do: values
  defp keep(values, value, samples), do: Enum.take([value | values], samples)

  defp config(socket), do: ProcessOptions.config(socket.assigns[:config])

  ## Timers

  @doc """
  Schedules the next tick of `kind`, replacing any pending one. Nothing is
  scheduled without a target; a dead one stops the sample loop, while the
  relations loop goes on (to find a replacement, or drop it).
  """
  @spec schedule(Socket.t(), kind(), module()) :: Socket.t()
  def schedule(%{assigns: %{selected: pid, sample: sample}} = socket, kind, module)
      when is_pid(pid) and (kind == :relations or sample != :dead) do
    socket = cancel_timer(socket, kind)
    token = make_ref()
    every = Map.fetch!(config(socket), interval_key(kind))
    ref = Panel.send_after(module, socket.assigns.id, {kind, token}, every)
    update(socket, :timers, &Map.put(&1, kind, {ref, token}))
  end

  def schedule(socket, kind, _module), do: cancel_timer(socket, kind)

  @doc """
  Takes the tick `{kind, token}` if it is the pending timer of its kind: one
  loop per kind, whatever raced (a tick already queued when its timer was
  replaced is `:stale`).
  """
  @spec take_tick(Socket.t(), kind(), reference()) :: {:ok, Socket.t()} | :stale
  def take_tick(socket, kind, token) do
    case socket.assigns.timers do
      %{^kind => {_ref, ^token}} -> {:ok, update(socket, :timers, &Map.delete(&1, kind))}
      _stale -> :stale
    end
  end

  @doc "Cancels both pending timers."
  @spec cancel_timers(Socket.t()) :: Socket.t()
  def cancel_timers(socket), do: socket |> cancel_timer(:sample) |> cancel_timer(:relations)

  defp interval_key(:sample), do: :sample_ms
  defp interval_key(:relations), do: :relations_ms

  defp cancel_timer(socket, kind) do
    case socket.assigns.timers do
      %{^kind => {ref, _token}} ->
        _ = Process.cancel_timer(ref)
        update(socket, :timers, &Map.delete(&1, kind))

      _none ->
        socket
    end
  end

  ## GC now

  @doc """
  The only thing the Process tab does to a host process (ADR 09): a garbage
  collection, to tell retained memory from garbage. In a task, so a target busy
  in a long NIF never blocks the panel; at most once a second.
  """
  @spec gc(Socket.t(), module()) :: Socket.t()
  # A suspended process would only collect once resumed: the task would wait.
  def gc(%{assigns: %{sample: %{status: :suspended}}} = socket, _module),
    do: assign(socket, :gc, :suspended)

  def gc(%{assigns: %{selected: pid, gc: gc}} = socket, module)
      when is_pid(pid) and gc != :running do
    case gc_allowed?(socket) do
      true ->
        socket
        |> assign(gc: :running, gc_at: System.monotonic_time(:millisecond))
        |> start_async(:gc, fn -> {pid, ProcessInfo.collect(pid)} end)

      # The last result stays; a note says when the next collection is allowed.
      false ->
        socket |> assign(:gc_note, "at most one collection a second") |> gc_ready_later(module)
    end
  end

  def gc(socket, _module), do: socket

  @doc "The collection's task ended (the `handle_async(:gc, ...)` result)."
  @spec gc_done(Socket.t(), {:ok, term()} | {:exit, term()}) :: Socket.t()
  def gc_done(%{assigns: %{selected: pid}} = socket, {:ok, {pid, result}}),
    do: socket |> assign(:gc, result) |> read_sample()

  # The target changed meanwhile (its task was cancelled), or the task exited.
  def gc_done(socket, _result), do: assign(socket, :gc, nil)

  @doc "The `:gc_ready` message: a collection is allowed again."
  @spec gc_ready(Socket.t()) :: Socket.t()
  def gc_ready(socket), do: assign(socket, gc_note: nil, gc_timer: nil)

  defp gc_ready_later(%{assigns: %{gc_timer: nil, gc_at: at}} = socket, module) do
    wait = max(@gc_every_ms - (System.monotonic_time(:millisecond) - at), 0)
    assign(socket, :gc_timer, Panel.send_after(module, socket.assigns.id, :gc_ready, wait))
  end

  defp gc_ready_later(socket, _module), do: socket

  defp gc_allowed?(%{assigns: %{gc_at: nil}}), do: true

  defp gc_allowed?(%{assigns: %{gc_at: at}}),
    do: System.monotonic_time(:millisecond) - at >= @gc_every_ms

  ## Actions (ADR 10)

  @kill_reasons ["kill", "shutdown", "crash"]
  # At most one action a second.
  @action_every_ms 1000

  @doc """
  The context ProcessActions needs: the client and the panel's own processes,
  from the `pdt_actions` assign the toolbar gives every tab.
  """
  @spec context(Socket.t()) :: ProcessActions.context()
  def context(socket), do: Map.merge(%{panel: self()}, socket.assigns[:pdt_actions] || %{})

  @doc "Whether the selected process may be killed or suspended from here, and why not."
  @spec gate(Socket.t() | map()) :: :ok | {:error, String.t()}
  def gate(%{selected: pid} = assigns) when is_pid(pid),
    do: ProcessActions.allowed(pid, Map.merge(%{panel: self()}, assigns[:pdt_actions] || %{}))

  def gate(_assigns), do: {:error, "No process selected."}

  @doc "The first click: the action waits for a confirm (`arm` event params)."
  @spec arm(Socket.t(), map()) :: Socket.t()
  def arm(socket, %{"action" => "kill", "reason" => reason}) when reason in @kill_reasons,
    do: assign(socket, confirm: {:kill, reason}, note: nil)

  def arm(socket, %{"action" => "suspend"}), do: assign(socket, confirm: :suspend, note: nil)
  def arm(socket, _params), do: socket

  @doc "Drops the action waiting for a confirm."
  @spec cancel(Socket.t()) :: Socket.t()
  def cancel(socket), do: assign(socket, :confirm, nil)

  @doc "The confirm click: runs the armed action, at most one a second."
  @spec confirm(Socket.t()) :: Socket.t()
  def confirm(%{assigns: %{selected: pid, confirm: action}} = socket)
      when is_pid(pid) and action != nil do
    case action_allowed?(socket) do
      true ->
        socket
        |> assign(confirm: nil, action_at: System.monotonic_time(:millisecond))
        |> assign(:note, run(action, pid, context(socket)))
        |> read_sample()

      false ->
        assign(socket, :note, {:error, "One action a second: try again."})
    end
  end

  def confirm(socket), do: socket

  @doc "Resumes the selected process, if the toolbar suspended it."
  @spec resume(Socket.t()) :: Socket.t()
  def resume(%{assigns: %{selected: pid}} = socket) when is_pid(pid) do
    note =
      case ProcessActions.resume(pid) do
        :ok -> {:ok, "Resumed."}
        {:error, why} -> {:error, why}
      end

    socket |> assign(:note, note) |> read_sample()
  end

  def resume(socket), do: socket

  defp run({:kill, reason}, pid, context) do
    case ProcessActions.kill(pid, reason, context) do
      :ok -> {:ok, "Exit signal sent (#{reason})."}
      error -> error
    end
  end

  defp run(:suspend, pid, context) do
    case ProcessActions.suspend(pid, context) do
      :ok -> {:ok, "Suspended for 10 s: it resumes by itself."}
      error -> error
    end
  end

  defp action_allowed?(%{assigns: %{action_at: nil}}), do: true

  defp action_allowed?(%{assigns: %{action_at: at}}),
    do: System.monotonic_time(:millisecond) - at >= @action_every_ms
end
