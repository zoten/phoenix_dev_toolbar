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
  alias PhoenixDevToolbar.ProcessActions
  alias PhoenixDevToolbar.ProcessControls
  alias PhoenixDevToolbar.ProcessInfo
  alias PhoenixDevToolbar.ProcessInspector
  alias PhoenixDevToolbar.ProcessRef
  alias PhoenixDevToolbar.ProcessTop
  alias PhoenixDevToolbar.ProcessTree
  alias PhoenixDevToolbar.ProcessView
  alias PhoenixDevToolbar.SystemView
  alias PhoenixDevToolbar.Tracer
  alias PhoenixDevToolbar.Truncate

  @max_crumbs 20
  @max_watched 10
  @status_timeout_ms 1000
  # At most one state read per second.
  @status_every_ms 1000

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(prev: nil, crumbs: [], error: nil, query: "")
     |> assign(ancestors: [], stacktrace: [], status: nil, status_at: nil)
     |> assign(watched: [], peek: nil, children: nil, apps: nil)
     |> assign(top: nil, top_by: "memory", top_at: nil, trace: nil)
     |> ProcessInspector.init()}
  end

  @impl Panel
  def handle_reset(_events, socket),
    do: socket |> update(:watched, &Enum.map(&1, fn watch -> recheck(watch) end)) |> poll_now()

  @impl Panel
  def handle_events(_events, socket), do: socket

  # The tab selected or the panel visible again: read now and restart polling.
  # The page does not matter here: the inspected process stays.
  @impl Panel
  def handle_props(%{assigns: assigns} = socket) do
    prev = assigns.prev || %{shown?: false, visible?: false}
    socket = assign(socket, :prev, Map.take(assigns, [:shown?, :visible?]))

    case not (prev.shown? and prev.visible?) and ProcessInspector.polling?(socket) do
      true -> socket |> poll_now() |> maybe_load_apps()
      false -> socket
    end
  end

  @impl Panel
  def handle_info({:navigate, %{"pid" => ref}}, socket), do: inspect_ref(socket, ref)

  def handle_info({kind, token}, socket) when kind in [:sample, :relations],
    do: ProcessInspector.handle_tick(socket, kind, token, &tick/2, &schedule/2)

  def handle_info(:gc_ready, socket), do: ProcessInspector.gc_ready(socket)

  # A watched process exited (the monitor is the panel's: PanelLive forwards it).
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket),
    do: update(socket, :watched, &Enum.map(&1, fn watch -> down(watch, ref, reason) end))

  def handle_info(_message, socket), do: socket

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

  def handle_event("status", _params, socket), do: {:noreply, read_status(socket)}

  def handle_event("watch", _params, socket), do: {:noreply, watch(socket)}

  def handle_event("trace", _params, socket), do: {:noreply, start_trace(socket)}
  def handle_event("trace_stop", _params, socket), do: {:noreply, stop_trace(socket)}

  def handle_event("refresh_children", _params, socket), do: {:noreply, load_children(socket)}

  def handle_event("top_by", %{"by" => by}, socket) when is_binary(by),
    do: {:noreply, pick_top(socket, by)}

  # An unknown sort reads nothing (not the previous one).
  def handle_event("top", %{"by" => by}, socket) when is_binary(by) do
    case ProcessTop.sort(by) do
      {:ok, _sort} -> {:noreply, socket |> pick_top(by) |> read_top()}
      :error -> {:noreply, socket}
    end
  end

  # Back to the applications list: nothing inspected, crumbs kept.
  def handle_event("apps", _params, socket) do
    {:noreply,
     socket
     |> clear_trace()
     |> cancel_status()
     |> ProcessInspector.cancel_timers()
     |> ProcessInspector.select(nil)
     |> assign(error: nil, children: nil, peek: nil, apps: nil)
     |> maybe_load_apps()}
  end

  def handle_event("unwatch", %{"index" => index}, socket) when is_binary(index),
    do: {:noreply, unwatch(socket, Integer.parse(index))}

  def handle_event("peek", _params, %{assigns: %{selected: pid}} = socket) when is_pid(pid),
    do:
      {:noreply, assign(socket, :peek, ProcessActions.peek(pid, ProcessControls.context(socket)))}

  # GC now, Kill, Suspend, Resume (ADR 09, ADR 10): ProcessControls; anything
  # else is ignored.
  def handle_event(event, params, socket),
    do: {:noreply, ProcessControls.handle_event(event, params, socket, SystemPanel)}

  @impl Phoenix.LiveComponent
  def handle_async(:gc, result, socket), do: {:noreply, ProcessInspector.gc_done(socket, result)}

  def handle_async(:status, {:ok, {pid, result}}, %{assigns: %{selected: pid}} = socket),
    do: {:noreply, assign(socket, :status, result)}

  # The target changed meanwhile (its task was cancelled), or the task exited.
  def handle_async(:status, _result, socket), do: {:noreply, assign(socket, :status, nil)}

  def handle_async(:children, {:ok, {pid, result}}, %{assigns: %{selected: pid}} = socket),
    do: {:noreply, assign(socket, :children, result)}

  def handle_async(:children, _result, socket), do: {:noreply, assign(socket, :children, nil)}

  def handle_async(:top, {:ok, result}, socket), do: {:noreply, assign(socket, :top, result)}
  def handle_async(:top, _exit, socket), do: {:noreply, assign(socket, :top, nil)}

  def handle_async(:apps, {:ok, result}, socket), do: {:noreply, assign(socket, :apps, result)}

  def handle_async(:apps, _exit, socket),
    do: {:noreply, assign(socket, :apps, {:error, :timeout})}

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
    |> clear_trace()
    |> cancel_status()
    |> ProcessInspector.cancel_timers()
    |> ProcessInspector.select(pid)
    |> assign(error: nil, ancestors: [], stacktrace: [], status: nil, status_at: nil, peek: nil)
    |> load_children()
    |> poll_now()
  end

  defp error(:invalid), do: "Type a pid like <0.123.0> or a registered name."
  defp error(:not_found), do: "No process is registered under that name."
  defp error(:remote), do: "That process runs on another node: only local ones can be inspected."
  defp error(:dead), do: "That process has exited."

  ## Trees (ProcessTree: calls into host processes, always in a task)

  @tree_timeout_ms 1000

  defp load_children(%{assigns: %{selected: pid}} = socket) when is_pid(pid) do
    case ProcessTree.supervisor?(pid) do
      true ->
        socket
        |> assign(:children, :loading)
        |> start_async(:children, fn -> {pid, ProcessTree.children(pid, @tree_timeout_ms)} end)

      false ->
        assign(socket, :children, nil)
    end
  end

  defp load_children(socket), do: assign(socket, :children, nil)

  defp maybe_load_apps(%{assigns: %{selected: nil, apps: nil}} = socket) do
    case ProcessInspector.polling?(socket) do
      true ->
        socket
        |> assign(:apps, :loading)
        |> start_async(:apps, fn -> ProcessTree.applications(@tree_timeout_ms) end)

      false ->
        socket
    end
  end

  defp maybe_load_apps(socket), do: socket

  ## Top (ProcessTop: a sweep of every process, in a task, on a click)

  # At most one sweep a second.
  @top_every_ms 1000

  defp pick_top(socket, by) do
    case ProcessTop.sort(by) do
      {:ok, _sort} -> assign(socket, :top_by, by)
      :error -> socket
    end
  end

  defp read_top(%{assigns: %{top: :loading}} = socket), do: socket

  defp read_top(%{assigns: %{top_by: by, top_at: at}} = socket) do
    case top_allowed?(at) do
      true ->
        {:ok, sort} = ProcessTop.sort(by)

        socket
        |> assign(top: :loading, top_at: System.monotonic_time(:millisecond))
        |> start_async(:top, fn -> ProcessTop.top(sort) end)

      false ->
        socket
    end
  end

  defp top_allowed?(nil), do: true
  defp top_allowed?(at), do: System.monotonic_time(:millisecond) - at >= @top_every_ms

  ## Trace (Tracer: one trace on the node, OTP 27+)

  # Like peek it copies the process's messages, and tracing the toolbar or core
  # processes could loop: the actions policy and the protected set apply (ADR 10).
  defp start_trace(%{assigns: %{selected: pid}} = socket) when is_pid(pid) do
    with :ok <- ProcessActions.allowed(pid, ProcessControls.context(socket)),
         :ok <- Tracer.start(pid, self()) do
      read_trace(assign(socket, :trace, :starting))
    else
      {:error, :busy} ->
        assign(
          socket,
          :trace,
          {:error, "Another panel is tracing a process: one trace at a time."}
        )

      {:error, :dead} ->
        assign(socket, :trace, {:error, "It has exited."})

      {:error, :unavailable} ->
        assign(socket, :trace, {:error, "The tracer did not answer: try again."})

      {:error, why} when is_binary(why) ->
        assign(socket, :trace, {:error, why})
    end
  end

  defp start_trace(socket), do: socket

  defp stop_trace(%{assigns: %{trace: nil}} = socket), do: socket

  defp stop_trace(socket) do
    :ok = Tracer.stop(self())
    read_trace(socket)
  end

  # Another target: its trace stops and goes, it belonged to the previous one.
  defp clear_trace(%{assigns: %{trace: nil}} = socket), do: socket

  defp clear_trace(socket) do
    :ok = Tracer.stop(self())
    assign(socket, :trace, nil)
  end

  # On every sample tick while a trace is shown: its events so far. A cleared
  # trace (the target changed) reads nil.
  defp read_trace(%{assigns: %{trace: trace}} = socket) when trace == :starting or is_map(trace),
    do: assign(socket, :trace, Tracer.status(self()))

  defp read_trace(socket), do: socket

  ## Watch

  # The panel monitors at most @max_watched processes, newest first; each one
  # keeps its exit reason and time once down. Watching only monitors: open to
  # every client (ADR 10).
  defp watch(%{assigns: %{selected: pid, watched: watched}} = socket) when is_pid(pid) do
    case Enum.any?(watched, &(&1.pid == pid)) or length(watched) >= @max_watched do
      true ->
        socket

      # Routed to this tab only (Panel.monitor/3). Exited before the route was
      # set: its DOWN is lost, so it is marked here.
      false ->
        ref = Panel.monitor(SystemPanel, socket.assigns.id, pid)
        watch = %{pid: pid, label: label(pid), ref: ref, down: nil}
        assign(socket, :watched, [recheck(watch) | watched])
    end
  end

  defp watch(socket), do: socket

  defp unwatch(socket, {index, ""}) when index >= 0 do
    case Enum.at(socket.assigns.watched, index) do
      %{ref: ref} ->
        Panel.demonitor(ref)
        update(socket, :watched, &List.delete_at(&1, index))

      nil ->
        socket
    end
  end

  defp unwatch(socket, _index), do: socket

  defp down(%{ref: ref, down: nil} = watch, ref, reason) do
    at = (Time.utc_now() |> Time.truncate(:second) |> Time.to_string()) <> " UTC"

    %{
      watch
      | down: %{at: at, reason: Truncate.inspect_value(reason, limit: 10, printable_limit: 200)}
    }
  end

  defp down(watch, _ref, _reason), do: watch

  # A DOWN that arrived while this tab was disabled was dropped: a watch still
  # "alive" whose process is gone is marked on the next reset.
  defp recheck(%{down: nil, pid: pid, ref: ref} = watch) do
    case Process.alive?(pid) do
      true -> watch
      false -> down(watch, ref, :exited_unseen)
    end
  end

  defp recheck(watch), do: watch

  ## Polling

  defp poll_now(socket) do
    case ProcessInspector.polling?(socket) do
      true ->
        socket
        |> ProcessInspector.read_all()
        |> read_where()
        |> read_trace()
        |> schedule(:sample)
        |> schedule(:relations)

      false ->
        socket
    end
  end

  defp tick(socket, :sample), do: socket |> ProcessInspector.read_sample() |> read_trace()

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
  # It copies the process's data: like message peek, it follows `actions:` (ADR 10).
  defp read_status(%{assigns: %{selected: pid, status: status, status_at: at}} = socket)
       when is_pid(pid) and status != :running do
    cond do
      not ProcessControls.client?(socket) ->
        assign(socket, :status, {:error, :policy})

      status_allowed?(at) ->
        socket
        |> assign(status: :running, status_at: System.monotonic_time(:millisecond))
        |> start_async(:status, fn -> {pid, ProcessInfo.status(pid, @status_timeout_ms)} end)

      true ->
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
        <button
          :if={is_pid(@selected)}
          id="pdt-system-apps-button"
          type="button"
          class="pdt-button pdt-button--small"
          phx-click="apps"
          phx-target={@myself}
        >
          Applications
        </button>
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
        Type a pid or a registered name, follow a process link from the Process tab, or
        start from an application below.
      </p>
      <section :if={is_nil(@selected)} id="pdt-system-top" class="pdt-system__state">
        <h3 class="pdt-process__title">Top processes</h3>
        <form
          id="pdt-system-top-form"
          class="pdt-actions__kill"
          phx-change="top_by"
          phx-submit="top"
          phx-target={@myself}
        >
          <select id="pdt-system-top-by" name="by" aria-label="Sort by">
            <option value="memory" selected={@top_by == "memory"}>by memory</option>
            <option value="reductions" selected={@top_by == "reductions"}>
              by reductions per second
            </option>
            <option value="queue" selected={@top_by == "queue"}>by message queue</option>
          </select>
          <button
            id="pdt-system-top-read"
            type="submit"
            class="pdt-button pdt-button--small"
            aria-busy={to_string(@top == :loading)}
          >
            {if(@top == :loading, do: "reading…", else: "Read")}
          </button>
        </form>
        <SystemView.top top={@top} target={@myself} />
      </section>
      <section :if={is_nil(@selected)} id="pdt-system-apps" class="pdt-system__state">
        <h3 class="pdt-process__title">Applications</h3>
        <SystemView.apps apps={@apps} target={@myself} />
      </section>
      <div :if={is_pid(@selected)} id="pdt-system-target" class="pdt-snapshot-bar">
        <strong :if={@about && @about.name}>{@about.name}</strong>
        <code>{inspect(@selected)}</code>
        <span :if={@about} class="pdt-hint">
          started in <code>{@about.initial_call}</code>
          <span :if={@about.trap_exit}> · traps exits</span>
        </span>
        <ProcessView.gc_control
          :if={is_map(@sample)}
          prefix="pdt-system"
          target={@myself}
          gc={@gc}
          gc_note={@gc_note}
        />
      </div>
      <ProcessView.paused :if={is_pid(@selected) and not (@shown? and @visible?)} />
      <p :if={@sample == :dead} id="pdt-system-dead" class="pdt-empty">
        This process has exited.<span :if={@note} id="pdt-system-action-note">{elem(@note, 1)}</span>
      </p>
      <div :if={is_map(@sample)} id="pdt-system-act" class="pdt-snapshot-bar pdt-actions-bar">
        <ProcessView.actions
          prefix="pdt-system"
          target={@myself}
          gate={@gate}
          confirm={@confirm}
          note={@note}
          kill_reason={@kill_reason}
          suspended?={@sample.status == :suspended}
        />
        <button
          id="pdt-system-watch"
          type="button"
          class="pdt-button pdt-button--small"
          phx-click="watch"
          phx-target={@myself}
          disabled={Enum.any?(@watched, &(&1.pid == @selected)) or length(@watched) >= max_watched()}
          title={watch_title(@watched, @selected)}
        >
          Watch
        </button>
        <button
          :if={ProcessControls.client?(%{pdt_actions: @pdt_actions})}
          id="pdt-system-peek"
          type="button"
          class="pdt-button pdt-button--small"
          phx-click="peek"
          phx-target={@myself}
          title="Show the first messages in its queue (fewer than 100 queued)"
        >
          Peek messages
        </button>
        <button
          :if={
            Tracer.available?() and @gate == :ok and
              not (is_map(@trace) and @trace.running?)
          }
          id="pdt-system-trace-start"
          type="button"
          class="pdt-button pdt-button--small"
          phx-click="trace"
          phx-target={@myself}
          title={"Record what it receives and sends: #{Tracer.max_events()} messages or 10 s at most"}
        >
          Trace messages
        </button>
        <span :if={not Tracer.available?() and @gate == :ok} class="pdt-hint">
          Message trace needs OTP 27.
        </span>
      </div>
      <section :if={@trace} id="pdt-system-trace" class="pdt-system__state">
        <h3 class="pdt-process__title">
          Message trace
          <button
            :if={is_map(@trace) and @trace.running?}
            id="pdt-system-trace-stop"
            type="button"
            class="pdt-button pdt-button--small"
            phx-click="trace_stop"
            phx-target={@myself}
          >
            Stop
          </button>
        </h3>
        <SystemView.trace trace={@trace} target={@myself} />
      </section>
      <section :if={@peek} id="pdt-system-messages" class="pdt-system__state">
        <h3 class="pdt-process__title">Messages</h3>
        <SystemView.peek peek={@peek} />
      </section>
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
      <section :if={@children} id="pdt-system-children" class="pdt-system__state">
        <h3 class="pdt-process__title">
          Children
          <button
            id="pdt-system-children-refresh"
            type="button"
            class="pdt-button pdt-button--small"
            phx-click="refresh_children"
            phx-target={@myself}
          >
            Refresh
          </button>
        </h3>
        <SystemView.children children={@children} target={@myself} />
      </section>
      <section
        :if={
          (is_map(@sample) and @about) && @about.otp? &&
            ProcessControls.client?(%{pdt_actions: @pdt_actions})
        }
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
        <SystemView.status status={@status} />
      </section>
      <section :if={@watched != []} id="pdt-system-watched" class="pdt-system__state">
        <h3 class="pdt-process__title">Watched ({length(@watched)})</h3>
        <ul class="pdt-list">
          <li
            :for={{watch, index} <- Enum.with_index(@watched)}
            id={"pdt-system-watched-#{index}"}
            class="pdt-row pdt-process__relation"
          >
            <ProcessView.pid_link
              id={inspect(watch.pid)}
              link={is_nil(watch.down) && "inspect"}
              target={@myself}
            />
            <span>{watch.label}</span>
            <span :if={is_nil(watch.down)} class="pdt-tag pdt-tag--live">alive</span>
            <span :if={watch.down} class="pdt-system__down">
              exited at {watch.down.at}: <code>{watch.down.reason}</code>
            </span>
            <button
              id={"pdt-system-forget-#{index}"}
              type="button"
              class="pdt-button pdt-button--small"
              aria-label={"Forget #{inspect(watch.pid)}"}
              phx-click="unwatch"
              phx-value-index={index}
              phx-target={@myself}
            >
              Forget
            </button>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  defp max_watched, do: @max_watched

  defp watch_title(watched, pid) do
    cond do
      Enum.any?(watched, &(&1.pid == pid)) -> "Watched already"
      length(watched) >= @max_watched -> "#{@max_watched} watched: forget one first"
      true -> "Keep an eye on it: its exit reason shows below when it goes down"
    end
  end
end
