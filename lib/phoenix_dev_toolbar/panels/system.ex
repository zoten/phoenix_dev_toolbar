defmodule PhoenixDevToolbar.Panels.System do
  @moduledoc false
  # The System tab (ADR 11): any local process, named by what someone typed or a
  # link they followed (Panel.navigate/3 from the Process tab, a relation here).
  # Every reference is client input: it goes through ProcessRef.parse/1, which
  # creates no atom. Read only while the tab is shown and the panel visible, like
  # the Process tab (PhoenixDevToolbar.ProcessInspector); the ancestors and the
  # stacktrace are read with the relations, the state only on a click.
  #
  # Breadcrumbs: every process inspected, at most @max_crumbs, oldest dropped,
  # kept newest first. A crumb is clicked by its index in the rendered (oldest
  # first) list, never by pid. The inspected process is always the newest crumb:
  # going back to one drops those after it.

  use PhoenixDevToolbar.Panel

  alias PhoenixDevToolbar.Panel
  alias PhoenixDevToolbar.Panels.System, as: SystemPanel
  alias PhoenixDevToolbar.ProcessInfo
  alias PhoenixDevToolbar.ProcessInspector
  alias PhoenixDevToolbar.ProcessRef
  alias PhoenixDevToolbar.ProcessView

  @max_crumbs 20
  @status_timeout_ms 1000
  # At most one state read per second.
  @status_every_ms 1000

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(prev: nil, crumbs: [], error: nil, query: "")
     |> assign(ancestors: [], stacktrace: [], status: nil, status_at: nil)
     |> ProcessInspector.init()}
  end

  @impl Panel
  def handle_reset(_events, socket), do: poll_now(socket)

  @impl Panel
  def handle_events(_events, socket), do: socket

  # The tab selected or the panel visible again: read now and restart polling.
  # The page does not matter here: the inspected process stays.
  @impl Panel
  def handle_props(%{assigns: assigns} = socket) do
    prev = assigns.prev || %{shown?: false, visible?: false}
    socket = assign(socket, :prev, Map.take(assigns, [:shown?, :visible?]))

    case not (prev.shown? and prev.visible?) and polling?(socket) do
      true -> poll_now(socket)
      false -> socket
    end
  end

  @impl Panel
  def handle_info({:navigate, %{"pid" => ref}}, socket), do: inspect_ref(socket, ref)

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

  @impl Phoenix.LiveComponent
  def handle_event("search", %{"ref" => ref}, socket) when is_binary(ref),
    do: {:noreply, socket |> assign(:query, query(ref)) |> inspect_ref(ref)}

  def handle_event("inspect", %{"pid" => ref}, socket) when is_binary(ref),
    do: {:noreply, inspect_ref(socket, ref)}

  # Typing keeps the query across renders (and form recovery).
  def handle_event("query", %{"ref" => ref}, socket) when is_binary(ref),
    do: {:noreply, assign(socket, :query, query(ref))}

  def handle_event("crumb", %{"index" => index}, socket) when is_binary(index) do
    oldest_first = Enum.reverse(socket.assigns.crumbs)

    with {index, ""} <- Integer.parse(index),
         %{pid: pid} <- index >= 0 && Enum.at(oldest_first, index) do
      {:noreply,
       socket
       |> assign(:crumbs, oldest_first |> Enum.take(index + 1) |> Enum.reverse())
       |> show(pid)}
    else
      _other -> {:noreply, socket}
    end
  end

  def handle_event("gc", _params, socket),
    do: {:noreply, ProcessInspector.gc(socket, SystemPanel)}

  def handle_event("status", _params, socket), do: {:noreply, read_status(socket)}
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveComponent
  def handle_async(:gc, result, socket), do: {:noreply, ProcessInspector.gc_done(socket, result)}

  def handle_async(:status, {:ok, {pid, result}}, %{assigns: %{selected: pid}} = socket),
    do: {:noreply, assign(socket, :status, result)}

  # The target changed meanwhile (its task was cancelled), or the task exited.
  def handle_async(:status, _result, socket), do: {:noreply, assign(socket, :status, nil)}

  # The input's maxlength is client side only: what is kept is capped here.
  defp query(ref), do: String.slice(ref, 0, 128)

  ## Targets

  defp inspect_ref(socket, ref) when is_binary(ref) do
    case ProcessRef.parse(ref) do
      {:ok, pid} -> socket |> push_crumb(pid) |> show(pid)
      {:error, reason} -> assign(socket, :error, error(reason))
    end
  end

  defp inspect_ref(socket, _ref), do: socket

  # The same process twice in a row is one crumb.
  defp push_crumb(%{assigns: %{crumbs: [%{pid: pid} | _older]}} = socket, pid), do: socket

  defp push_crumb(%{assigns: %{crumbs: crumbs}} = socket, pid) do
    crumb = %{pid: pid, label: label(pid)}
    assign(socket, :crumbs, Enum.take([crumb | crumbs], @max_crumbs))
  end

  defp label(pid) do
    case ProcessInfo.about(pid) do
      %{name: name} when is_binary(name) -> name
      %{initial_call: call} -> call
      nil -> inspect(pid)
    end
  end

  defp show(socket, pid) do
    socket
    |> cancel_status()
    |> ProcessInspector.cancel_timers()
    |> ProcessInspector.select(pid)
    |> assign(error: nil, ancestors: [], stacktrace: [], status: nil, status_at: nil)
    |> poll_now()
  end

  defp error(:invalid), do: "Type a pid like <0.123.0> or a registered name."
  defp error(:not_found), do: "No process is registered under that name."
  defp error(:remote), do: "That process runs on another node: only local ones can be inspected."
  defp error(:dead), do: "That process has exited."

  ## Polling

  defp polling?(%{assigns: %{shown?: true, visible?: true}}), do: true
  defp polling?(_socket), do: false

  defp poll_now(socket) do
    case polling?(socket) do
      true ->
        socket
        |> ProcessInspector.read_all()
        |> read_where()
        |> schedule(:sample)
        |> schedule(:relations)

      false ->
        socket
    end
  end

  defp tick(socket, :sample), do: ProcessInspector.read_sample(socket)

  defp tick(socket, :relations),
    do: socket |> ProcessInspector.read_relations() |> read_where()

  # An exited process stays shown, but nothing is read for it any more (the
  # Process tab keeps its relations loop to find a rejoined LiveView; here there
  # is nothing to find).
  defp schedule(%{assigns: %{sample: :dead}} = socket, _kind),
    do: ProcessInspector.cancel_timers(socket)

  defp schedule(socket, kind), do: ProcessInspector.schedule(socket, kind, SystemPanel)

  # Who started it and where it is now: cheap process_info reads.
  defp read_where(%{assigns: %{selected: pid}} = socket) when is_pid(pid),
    do:
      assign(socket,
        ancestors: ProcessInfo.ancestors(pid),
        stacktrace: ProcessInfo.stacktrace(pid)
      )

  defp read_where(socket), do: socket

  ## State

  # Runs code in the target (`:sys`): on a click only, in a task, at most once a
  # second, and only for processes that answer system messages.
  defp read_status(%{assigns: %{selected: pid, status: status, status_at: at}} = socket)
       when is_pid(pid) and status != :running do
    case status_allowed?(at) do
      true ->
        socket
        |> assign(status: :running, status_at: System.monotonic_time(:millisecond))
        |> start_async(:status, fn -> {pid, ProcessInfo.status(pid, @status_timeout_ms)} end)

      false ->
        assign(socket, :status, {:error, :too_soon})
    end
  end

  defp read_status(socket), do: socket

  defp status_allowed?(nil), do: true
  defp status_allowed?(at), do: System.monotonic_time(:millisecond) - at >= @status_every_ms

  defp cancel_status(%{assigns: %{status: :running}} = socket),
    do: socket |> cancel_async(:status) |> assign(:status, nil)

  defp cancel_status(socket), do: socket

  ## Render

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="pdt-system" class="pdt-process">
      <div class="pdt-snapshot-bar">
        <form
          id="pdt-system-search"
          class="pdt-system__search"
          phx-change="query"
          phx-submit="search"
          phx-target={@myself}
        >
          <label for="pdt-system-ref" class="pdt-hint">Process</label>
          <input
            id="pdt-system-ref"
            name="ref"
            type="text"
            value={@query}
            maxlength="128"
            placeholder="<0.123.0> or a registered name"
            autocomplete="off"
            spellcheck="false"
          />
          <button type="submit" class="pdt-button pdt-button--small">Inspect</button>
        </form>
      </div>
      <p :if={@error} id="pdt-system-error" class="pdt-error" role="alert">{@error}</p>
      <nav
        :if={@crumbs != []}
        id="pdt-system-crumbs"
        class="pdt-crumbs"
        aria-label="Inspected processes"
      >
        <button
          :for={{crumb, index} <- @crumbs |> Enum.reverse() |> Enum.with_index()}
          id={"pdt-system-crumb-#{index}"}
          type="button"
          class="pdt-crumb"
          aria-current={if(index == length(@crumbs) - 1, do: "true")}
          phx-click="crumb"
          phx-value-index={index}
          phx-target={@myself}
          title={inspect(crumb.pid)}
        >
          {crumb.label}
        </button>
      </nav>
      <p :if={is_nil(@selected) and is_nil(@error)} id="pdt-system-none" class="pdt-empty">
        Type a pid or a registered name, or follow a process link from the Process tab.
      </p>
      <div :if={is_pid(@selected)} id="pdt-system-target" class="pdt-snapshot-bar">
        <strong :if={@about && @about.name}>{@about.name}</strong>
        <code>{inspect(@selected)}</code>
        <span :if={@about} class="pdt-hint">
          started in <code>{@about.initial_call}</code>
          <span :if={@about.trap_exit}> · traps exits</span>
        </span>
        <button
          :if={is_map(@sample)}
          id="pdt-system-gc"
          type="button"
          class="pdt-button pdt-button--small"
          phx-click="gc"
          phx-target={@myself}
          aria-busy={to_string(@gc == :running)}
          title="Run a garbage collection on this process: what is left is memory it really holds"
        >
          {if(@gc == :running, do: "collecting…", else: "GC now")}
        </button>
        <span :if={is_map(@sample)} id="pdt-system-gc-result" class="pdt-hint" role="status">
          {ProcessView.gc_result(@gc)}<span :if={@gc_note}> · {@gc_note}</span>
        </span>
      </div>
      <p :if={is_pid(@selected) and not (@shown? and @visible?)} class="pdt-hint pdt-process__paused">
        Paused while the panel is hidden.
      </p>
      <p :if={@sample == :dead} id="pdt-system-dead" class="pdt-empty">This process has exited.</p>
      <ProcessView.vitals :if={is_map(@sample)} prefix="pdt-system" sample={@sample} series={@series} />
      <section :if={is_map(@sample)} id="pdt-system-where" class="pdt-process__relations">
        <div id="pdt-system-ancestors">
          <h3 class="pdt-process__title">Started by</h3>
          <p :if={@ancestors == []} class="pdt-hint">Unknown: not started through proc_lib.</p>
          <ol :if={@ancestors != []} class="pdt-list">
            <li :for={ancestor <- @ancestors} class="pdt-row pdt-process__relation">
              <ProcessView.pid_link
                id={ancestor.id}
                link={is_pid(ancestor.pid) && "inspect"}
                target={@myself}
              />
              <span>{ancestor.name}</span>
            </li>
          </ol>
        </div>
        <div id="pdt-system-stacktrace">
          <h3 class="pdt-process__title">Current stacktrace</h3>
          <p :if={@stacktrace == []} class="pdt-hint">None.</p>
          <ol :if={@stacktrace != []} class="pdt-list pdt-system__frames">
            <li :for={frame <- @stacktrace}><code>{frame}</code></li>
          </ol>
        </div>
      </section>
      <ProcessView.relations
        :if={is_map(@relations)}
        prefix="pdt-system"
        relations={@relations}
        link="inspect"
        target={@myself}
      />
      <section
        :if={(is_map(@sample) and @about) && @about.otp?}
        id="pdt-system-state"
        class="pdt-system__state"
      >
        <h3 class="pdt-process__title">
          State
          <button
            id="pdt-system-status"
            type="button"
            class="pdt-button pdt-button--small"
            phx-click="status"
            phx-target={@myself}
            aria-busy={to_string(@status == :running)}
            title="Ask the process for its state (:sys.get_status): runs its format_status, waits at most 1s"
          >
            {if(@status == :running, do: "reading…", else: "Read state")}
          </button>
        </h3>
        <.status status={@status} />
      </section>
    </div>
    """
  end

  attr :status, :any, required: true

  defp status(%{status: {:ok, _status}} = assigns) do
    ~H"""
    <p class="pdt-hint">{elem(@status, 1).module} · {elem(@status, 1).sys_state}</p>
    <pre id="pdt-system-state-value">{elem(@status, 1).state}</pre>
    """
  end

  defp status(%{status: {:error, reason}} = assigns) do
    assigns = assign(assigns, :message, status_error(reason))

    ~H"""
    <p id="pdt-system-state-error" class="pdt-hint" role="status">{@message}</p>
    """
  end

  defp status(assigns), do: ~H""

  defp status_error(:timeout), do: "No answer within 1s: the process is busy."
  defp status_error(:dead), do: "The process exited."
  defp status_error(:not_otp), do: "Not an OTP process: it does not answer :sys."

  defp status_error(:busy),
    do:
      "Not waiting in a server loop: busy in a callback (try again), or a Task, which never answers :sys."

  defp status_error(:failed), do: "The process failed to report its state."
  defp status_error(:too_soon), do: "One read a second: try again."
end
