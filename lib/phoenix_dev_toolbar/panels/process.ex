defmodule PhoenixDevToolbar.Panels.Process do
  @moduledoc false
  # The Process tab (ADR 09): the page's LiveView process (or a nested one),
  # read with PhoenixDevToolbar.ProcessInfo only while the tab is shown and the
  # panel visible: vital signs every `sample_ms`, kept as `samples` points for
  # the sparklines, links and monitors every `relations_ms`. The inspected
  # process's state and polling: PhoenixDevToolbar.ProcessInspector.
  #
  # The browser picks a process by its index in this page's list, never by pid.

  use PhoenixDevToolbar.Panel

  alias PhoenixDevToolbar.Page
  alias PhoenixDevToolbar.Panel
  alias PhoenixDevToolbar.Panels.Process, as: ProcessPanel
  alias PhoenixDevToolbar.ProcessInfo
  alias PhoenixDevToolbar.ProcessInspector
  alias PhoenixDevToolbar.ProcessView
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  # Nested LiveViews of one page listed at most.
  @max_targets 10

  @impl Phoenix.LiveComponent
  def mount(socket),
    do: {:ok, socket |> assign(prev: nil, targets: []) |> ProcessInspector.init()}

  # A reset also follows Re-enable (after an error broke the tab): polling
  # restarts if someone looks.
  @impl Panel
  def handle_reset(_events, socket), do: poll_now(socket)

  @impl Panel
  def handle_events(_events, socket), do: socket

  # A new page, the tab selected or the panel visible again: read now and
  # (re)start polling. Hidden: the timers are not renewed.
  @impl Panel
  def handle_props(%{assigns: assigns} = socket) do
    prev = assigns.prev || %{page: nil, shown?: false, visible?: false}
    socket = assign(socket, :prev, Map.take(assigns, [:page, :shown?, :visible?]))

    cond do
      # The list itself is only Store reads: the host process is read once polling.
      prev.page != assigns.page ->
        socket
        |> ProcessInspector.cancel_timers()
        |> ProcessInspector.select(nil)
        |> refresh_targets(false)
        |> poll_now()

      not (prev.shown? and prev.visible?) and polling?(socket) ->
        poll_now(socket)

      true ->
        socket
    end
  end

  @impl Panel
  def handle_info({kind, token}, socket) when kind in [:sample, :relations] do
    case ProcessInspector.take_tick(socket, kind, token) do
      {:ok, socket} -> continue(socket, kind, polling?(socket))
      :stale -> socket
    end
  end

  def handle_info(:gc_ready, socket), do: ProcessInspector.gc_ready(socket)
  def handle_info(_message, socket), do: socket

  defp continue(socket, kind, true), do: socket |> tick(kind) |> schedule(kind)
  defp continue(socket, _kind, false), do: socket

  # The index is into the list the user saw (rendered), never recomputed first.
  @impl Phoenix.LiveComponent
  def handle_event("select", %{"index" => index}, socket) when is_binary(index) do
    with {index, ""} <- Integer.parse(index),
         %{pid: pid} <- index >= 0 && Enum.at(socket.assigns.targets, index) do
      {:noreply,
       socket |> ProcessInspector.cancel_timers() |> ProcessInspector.select(pid) |> poll_now()}
    else
      _other -> {:noreply, socket}
    end
  end

  def handle_event("select", _params, socket), do: {:noreply, socket}

  def handle_event("gc", _params, socket),
    do: {:noreply, ProcessInspector.gc(socket, ProcessPanel)}

  @impl Phoenix.LiveComponent
  def handle_async(:gc, result, socket), do: {:noreply, ProcessInspector.gc_done(socket, result)}

  ## Targets

  # The list is refreshed when polling starts and on every relations tick: a
  # nested LiveView mounts after its parent (same sid, so the page does not
  # change). A selected process that left the list gives way to the first.
  # `named?`: nested LiveViews are named after their module, a read of the
  # process: only while polling (until the tab is opened, only the Store is read).
  defp refresh_targets(socket, named?) do
    targets = targets(socket.assigns.page, named?)
    selected = socket.assigns.selected
    socket = assign(socket, :targets, targets)

    case Enum.any?(targets, &(&1.pid == selected)) do
      true -> socket
      false -> ProcessInspector.select(socket, first_pid(targets))
    end
  end

  defp first_pid([%{pid: pid} | _rest]), do: pid
  defp first_pid([]), do: nil

  # The page's LiveView first, then the other live processes of its sids
  # (nested LiveViews), at most @max_targets. Exited pids linger in the index
  # until the Store's sweep: they are skipped.
  defp targets(%Page{sids: sids}, named?) do
    owners =
      for sid <- Enum.reverse(sids),
          {:ok, %Session{kind: :live_view, owner: owner, view: view}} <- [session(sid)],
          is_pid(owner) and Process.alive?(owner),
          do: %{pid: owner, label: label(view)}

    owner_pids = Enum.map(owners, & &1.pid)

    nested =
      for sid <- sids,
          pid <- pids_for(sid),
          pid not in owner_pids and Process.alive?(pid),
          do: %{pid: pid, label: nested_label(pid, named?)}

    Enum.take(owners ++ Enum.uniq_by(nested, & &1.pid), @max_targets)
  end

  defp nested_label(pid, true) do
    case ProcessInfo.module(pid) do
      nil -> "nested LiveView"
      module -> inspect(module) <> " (nested)"
    end
  end

  defp nested_label(_pid, false), do: "nested LiveView"

  defp label(nil), do: "LiveView"
  defp label(view), do: inspect(view)

  defp session(sid), do: safe(fn -> Store.session(sid) end, :error)
  defp pids_for(sid), do: safe(fn -> Store.pids_for(sid) end, [])

  # The Store's tables vanish while it restarts.
  defp safe(fun, default) do
    fun.()
  rescue
    ArgumentError -> default
  end

  ## Polling

  defp polling?(%{assigns: %{shown?: true, visible?: true}}), do: true
  defp polling?(_socket), do: false

  defp poll_now(socket) do
    case polling?(socket) do
      true ->
        socket
        |> refresh_targets(true)
        |> ProcessInspector.read_all()
        |> schedule(:sample)
        |> schedule(:relations)

      false ->
        socket
    end
  end

  defp tick(socket, :sample), do: ProcessInspector.read_sample(socket)

  # A new target found here (the LiveView crashed and rejoined with a new pid,
  # the selected nested one exited) restarts the sample loop, stopped on :dead.
  defp tick(socket, :relations) do
    before = socket.assigns.selected

    socket =
      socket
      |> refresh_targets(true)
      |> ProcessInspector.read_about()
      |> ProcessInspector.read_relations()

    case socket.assigns.selected do
      ^before -> socket
      _new -> socket |> ProcessInspector.read_sample() |> schedule(:sample)
    end
  end

  defp schedule(socket, kind), do: ProcessInspector.schedule(socket, kind, ProcessPanel)

  ## Render

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="pdt-process" class="pdt-process">
      <p :if={@targets == []} id="pdt-process-none" class="pdt-empty">
        No LiveView process: this page is a plain request, or its LiveView has not connected yet.
      </p>
      <div :if={@targets != []} class="pdt-snapshot-bar">
        <form
          :if={length(@targets) > 1}
          id="pdt-process-select"
          phx-change="select"
          phx-target={@myself}
        >
          <label for="pdt-process-target" class="pdt-hint">Process</label>
          <select id="pdt-process-target" name="index">
            <option
              :for={{target, index} <- Enum.with_index(@targets)}
              value={index}
              selected={target.pid == @selected}
            >
              {target.label} {inspect(target.pid)}
            </option>
          </select>
        </form>
        <span :if={length(@targets) == 1} id="pdt-process-target-label">
          <strong>{hd(@targets).label}</strong> <code>{inspect(hd(@targets).pid)}</code>
        </span>
        <span :if={@about} class="pdt-hint">
          started in <code>{@about.initial_call}</code>
          <span :if={@about.trap_exit}> · traps exits</span>
        </span>
        <button
          :if={is_map(@sample)}
          id="pdt-process-gc"
          type="button"
          class="pdt-button pdt-button--small"
          phx-click="gc"
          phx-target={@myself}
          aria-busy={to_string(@gc == :running)}
          title="Run a garbage collection on this process: what is left is memory it really holds"
        >
          {if(@gc == :running, do: "collecting…", else: "GC now")}
        </button>
        <span :if={is_map(@sample)} id="pdt-process-gc-result" class="pdt-hint" role="status">
          {ProcessView.gc_result(@gc)}<span :if={@gc_note} id="pdt-process-gc-note"> · {@gc_note}</span>
        </span>
      </div>
      <p :if={@targets != [] and not (@shown? and @visible?)} class="pdt-hint pdt-process__paused">
        Paused while the panel is hidden.
      </p>
      <p :if={@sample == :dead} id="pdt-process-dead" class="pdt-empty">
        This process has exited.
      </p>
      <ProcessView.vitals
        :if={is_map(@sample)}
        prefix="pdt-process"
        sample={@sample}
        series={@series}
      />
      <ProcessView.relations
        :if={is_map(@relations)}
        prefix="pdt-process"
        relations={@relations}
      />
    </div>
    """
  end
end
