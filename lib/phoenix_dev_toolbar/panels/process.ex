defmodule PhoenixDevToolbar.Panels.Process do
  @moduledoc false
  # The Process tab (ADR 09): the page's LiveView process (or a nested one),
  # read with PhoenixDevToolbar.ProcessInfo only while the tab is shown and the
  # panel visible: vital signs every `sample_ms`, kept as `samples` points for
  # the sparklines, links and monitors every `relations_ms`.
  #
  # The browser picks a process by its index in this page's list, never by pid.
  # Each timer carries a token: a tick that is not the pending timer of its
  # kind (replaced meanwhile) is dropped, so there is one loop per kind.

  use PhoenixDevToolbar.Panel

  import PhoenixDevToolbar.Components, only: [sparkline: 1, bytes: 1]

  alias PhoenixDevToolbar.Page
  alias PhoenixDevToolbar.Panel
  alias PhoenixDevToolbar.Plugins
  alias PhoenixDevToolbar.ProcessInfo
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  # Nested LiveViews of one page listed at most.
  @max_targets 10
  # At most one garbage collection per second, on the selected process only.
  @gc_every_ms 1000

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(prev: nil, targets: [], selected: nil, timers: %{})
     |> assign(gc: nil, gc_at: nil, gc_note: nil, gc_timer: nil)
     |> assign(about: nil, sample: nil, relations: nil, series: empty_series())}
  end

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
        socket |> cancel_timers() |> select(nil) |> refresh_targets(false) |> poll_now()

      not (prev.shown? and prev.visible?) and polling?(socket) ->
        poll_now(socket)

      true ->
        socket
    end
  end

  # A tick is honoured only if it is the pending timer of its kind: one loop per
  # kind, whatever raced (a tick already queued when its timer was replaced).
  @impl Panel
  def handle_info({kind, token}, socket) when kind in [:sample, :relations] do
    case socket.assigns.timers do
      %{^kind => {_ref, ^token}} ->
        socket = update(socket, :timers, &Map.delete(&1, kind))

        case polling?(socket) do
          true -> socket |> tick(kind) |> schedule(kind)
          false -> socket
        end

      _stale ->
        socket
    end
  end

  def handle_info(:gc_ready, socket), do: assign(socket, gc_note: nil, gc_timer: nil)

  def handle_info(_message, socket), do: socket

  # The index is into the list the user saw (rendered), never recomputed first.
  @impl Phoenix.LiveComponent
  def handle_event("select", %{"index" => index}, socket) when is_binary(index) do
    with {index, ""} <- Integer.parse(index),
         %{pid: pid} <- index >= 0 && Enum.at(socket.assigns.targets, index) do
      {:noreply, socket |> cancel_timers() |> select(pid) |> poll_now()}
    else
      _other -> {:noreply, socket}
    end
  end

  def handle_event("select", _params, socket), do: {:noreply, socket}

  # The only thing the toolbar does to a host process (ADR 09): a garbage
  # collection, to tell retained memory from garbage. In a task, so a target
  # busy in a long NIF never blocks the panel.
  def handle_event("gc", _params, %{assigns: %{selected: pid, gc: gc}} = socket)
      when is_pid(pid) and gc != :running do
    case gc_allowed?(socket) do
      true ->
        {:noreply,
         socket
         |> assign(gc: :running, gc_at: System.monotonic_time(:millisecond))
         |> start_async(:gc, fn -> {pid, ProcessInfo.collect(pid)} end)}

      # The last result stays; a note says when the next collection is allowed.
      false ->
        {:noreply,
         socket |> assign(:gc_note, "at most one collection a second") |> gc_ready_later()}
    end
  end

  def handle_event("gc", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveComponent
  def handle_async(:gc, {:ok, {pid, result}}, %{assigns: %{selected: pid}} = socket),
    do: {:noreply, socket |> assign(:gc, result) |> read_sample()}

  # The target changed meanwhile (its task was cancelled), or the task exited.
  def handle_async(:gc, _result, socket), do: {:noreply, assign(socket, :gc, nil)}

  defp gc_ready_later(%{assigns: %{gc_timer: nil, gc_at: at}} = socket) do
    wait = max(@gc_every_ms - (System.monotonic_time(:millisecond) - at), 0)
    assign(socket, :gc_timer, Panel.send_after(__MODULE__, socket.assigns.id, :gc_ready, wait))
  end

  defp gc_ready_later(socket), do: socket

  defp gc_allowed?(%{assigns: %{gc_at: nil}}), do: true

  defp gc_allowed?(%{assigns: %{gc_at: at}}),
    do: System.monotonic_time(:millisecond) - at >= @gc_every_ms

  ## Targets

  # A new target (nil: the page's LiveView, the first of the list): its data
  # starts over.
  defp select(socket, pid) do
    socket
    |> cancel_gc()
    |> assign(
      selected: pid,
      gc: nil,
      about: nil,
      gc_note: nil,
      sample: nil,
      relations: nil,
      series: empty_series()
    )
  end

  # A collection still running for the previous target (a process stuck in a
  # NIF) would otherwise leave its task behind.
  defp cancel_gc(%{assigns: %{gc: :running}} = socket),
    do: socket |> cancel_async(:gc) |> assign(:gc, nil)

  defp cancel_gc(socket), do: socket

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
      false -> select(socket, first_pid(targets))
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

  defp config(socket), do: Plugins.Process.config(socket.assigns[:config])

  defp poll_now(socket) do
    case polling?(socket) do
      true ->
        socket
        |> refresh_targets(true)
        |> read_about()
        |> read_sample()
        |> read_relations()
        |> schedule(:sample)
        |> schedule(:relations)

      false ->
        socket
    end
  end

  defp tick(socket, :sample), do: read_sample(socket)

  # A new target found here (the LiveView crashed and rejoined with a new pid,
  # the selected nested one exited) restarts the sample loop, stopped on :dead.
  defp tick(socket, :relations) do
    before = socket.assigns.selected
    socket = socket |> refresh_targets(true) |> read_about() |> read_relations()

    case socket.assigns.selected do
      ^before -> socket
      _new -> socket |> read_sample() |> schedule(:sample)
    end
  end

  # Replaces any pending timer of that kind. Nothing is scheduled without a
  # target; a dead one stops the sample loop, while the relations loop goes on
  # to find its replacement (a rejoin) or drop it from the list.
  defp schedule(%{assigns: %{selected: pid, sample: sample}} = socket, kind)
       when is_pid(pid) and (kind == :relations or sample != :dead) do
    socket = cancel_timer(socket, kind)
    token = make_ref()
    every = Map.fetch!(config(socket), :"#{kind}_ms")
    ref = Panel.send_after(__MODULE__, socket.assigns.id, {kind, token}, every)
    update(socket, :timers, &Map.put(&1, kind, {ref, token}))
  end

  defp schedule(socket, kind), do: cancel_timer(socket, kind)

  defp cancel_timers(socket), do: socket |> cancel_timer(:sample) |> cancel_timer(:relations)

  defp cancel_timer(socket, kind) do
    case socket.assigns.timers do
      %{^kind => {ref, _token}} ->
        _ = Process.cancel_timer(ref)
        update(socket, :timers, &Map.delete(&1, kind))

      _none ->
        socket
    end
  end

  defp read_about(%{assigns: %{selected: pid, about: nil}} = socket) when is_pid(pid),
    do: assign(socket, :about, ProcessInfo.about(pid))

  defp read_about(socket), do: socket

  defp read_sample(%{assigns: %{selected: pid}} = socket) when is_pid(pid) do
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

  defp read_sample(socket), do: socket

  defp read_relations(%{assigns: %{selected: pid}} = socket) when is_pid(pid),
    do: assign(socket, :relations, ProcessInfo.relations(pid))

  defp read_relations(socket), do: socket

  defp rate(%{at: _at} = previous, sample),
    do: ProcessInfo.reductions_per_second(previous, sample)

  defp rate(_none, _sample), do: nil

  defp empty_series, do: %{memory: [], queue: [], reductions: []}

  # Newest last, at most `samples` points per series.
  defp push(series, sample, rate, samples) do
    %{
      memory: keep(series.memory, sample.memory, samples),
      queue: keep(series.queue, sample.message_queue_len, samples),
      reductions: keep(series.reductions, rate, samples)
    }
  end

  defp keep(values, nil, _samples), do: values
  defp keep(values, value, samples), do: Enum.take(values ++ [value], -samples)

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
          {gc_result(@gc)}<span :if={@gc_note} id="pdt-process-gc-note"> · {@gc_note}</span>
        </span>
      </div>
      <p :if={@targets != [] and not (@shown? and @visible?)} class="pdt-hint pdt-process__paused">
        Paused while the panel is hidden.
      </p>
      <p :if={@sample == :dead} id="pdt-process-dead" class="pdt-empty">
        This process has exited.
      </p>
      <div
        :if={is_map(@sample)}
        id="pdt-process-vitals"
        class="pdt-process__vitals"
        data-samples={length(@series.memory)}
      >
        <.vital
          id="pdt-process-memory"
          label="Memory"
          value={bytes(@sample.memory)}
          values={@series.memory}
          peak={peak(@series.memory, &bytes/1)}
        />
        <.vital
          id="pdt-process-queue"
          label="Message queue"
          value={count(@sample.message_queue_len)}
          values={@series.queue}
          peak={peak(@series.queue, &count/1)}
          warn?={@sample.message_queue_len > 100}
        />
        <.vital
          id="pdt-process-reductions"
          label="Reductions / s"
          title="Work done per second: a reduction is roughly one function call"
          value={
            if(@sample.reductions_per_second,
              do: count(@sample.reductions_per_second),
              else: "…"
            )
          }
          values={@series.reductions}
          peak={peak(@series.reductions, &count/1)}
        />
      </div>
      <dl :if={is_map(@sample)} id="pdt-process-details" class="pdt-process__details">
        <dt>status</dt>
        <dd>
          {@sample.status}
          <span :if={@sample.status == :waiting and @sample.message_queue_len > 100} class="pdt-hint">
            · between two messages: the queue grows faster than they are handled
          </span>
        </dd>
        <dt>current function</dt>
        <dd><code>{@sample.current_function}</code></dd>
        <dt>heap</dt>
        <dd>
          {words(@sample.heap_size)} heap · {words(@sample.total_heap_size)} total · {words(
            @sample.stack_size
          )} stack
        </dd>
        <dt>GC</dt>
        <dd>
          {@sample.minor_gcs} minor collections since the last full sweep · a full sweep every {@sample.fullsweep_after} minor ones
        </dd>
      </dl>
      <section :if={is_map(@relations)} id="pdt-process-relations" class="pdt-process__relations">
        <.relation_list
          id="pdt-process-links"
          title="Links"
          relations={@relations.links}
          more={@relations.more.links}
        />
        <.relation_list
          id="pdt-process-monitors"
          title="Monitors"
          relations={@relations.monitors}
          more={@relations.more.monitors}
        />
        <.relation_list
          id="pdt-process-monitored-by"
          title="Monitored by"
          relations={@relations.monitored_by}
          more={@relations.more.monitored_by}
        />
      </section>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :values, :list, required: true
  attr :warn?, :boolean, default: false
  attr :peak, :string, default: nil, doc: "the window's highest value, formatted"
  attr :title, :string, default: nil

  defp vital(assigns) do
    ~H"""
    <div id={@id} class={["pdt-vital", @warn? && "pdt-vital--warn"]}>
      <span class="pdt-vital__label" title={@title}>{@label}</span>
      <span class="pdt-vital__value">{@value}</span>
      <.sparkline values={@values} label={sparkline_label(@label, @peak, length(@values))} />
      <span :if={@peak} class="pdt-vital__peak">peak {@peak} over {samples(length(@values))}</span>
    </div>
    """
  end

  # The line is scaled to its own window: the peak gives it a size.
  defp peak([], _format), do: nil
  defp peak(values, format), do: format.(Enum.max(values))

  defp sparkline_label(label, nil, _count), do: label <> " over time"

  defp sparkline_label(label, peak, count),
    do: "#{label} over the last #{samples(count)}, peak #{peak}"

  defp samples(1), do: "1 sample"
  defp samples(count), do: "#{count} samples"

  # 1234567 -> "1,234,567": reductions per second reach the millions.
  defp count(value) when is_integer(value),
    do: value |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+$)/, ",")

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :relations, :list, required: true
  attr :more, :integer, required: true

  defp relation_list(assigns) do
    ~H"""
    <div id={@id}>
      <h3 class="pdt-process__title">{@title} ({length(@relations) + @more})</h3>
      <p :if={@relations == []} class="pdt-hint">None.</p>
      <ul :if={@relations != []} class="pdt-list">
        <li :for={relation <- @relations} class="pdt-row pdt-process__relation">
          <code>{relation.id}</code>
          <span>{relation.name}</span>
          <span :if={relation.kind == :port} class="pdt-tag">port</span>
          <span :if={relation.toolbar?} class="pdt-tag" title="Part of the dev toolbar itself">
            toolbar
          </span>
          <span
            :if={relation.child?}
            class="pdt-tag pdt-tag--live"
            title="Started by this LiveView ($callers)"
          >
            child
          </span>
        </li>
      </ul>
      <p :if={@more > 0} class="pdt-hint">and {@more} more</p>
    </div>
    """
  end

  defp words(words), do: bytes(words * :erlang.system_info(:wordsize))

  defp gc_result({:ok, before, after_gc}) when before > after_gc,
    do: "freed #{bytes(before - after_gc)}: #{bytes(before)} → #{bytes(after_gc)}"

  defp gc_result({:ok, _before, after_gc}), do: "nothing to free: #{bytes(after_gc)} held"
  defp gc_result(:dead), do: "the process exited"
  defp gc_result(:too_soon), do: "one collection a second: try again"
  defp gc_result(_none_or_running), do: ""
end
