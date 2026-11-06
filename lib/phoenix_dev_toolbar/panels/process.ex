defmodule PhoenixDevToolbar.Panels.Process do
  @moduledoc false
  # The Process tab (ADR 09): the page's LiveView process (or a nested one),
  # read with PhoenixDevToolbar.ProcessInfo only while the tab is shown and the
  # panel visible: vital signs every `sample_ms`, kept as `samples` points for
  # the sparklines, links and monitors every `relations_ms`.
  #
  # The browser picks a process by its index in this page's list, never by pid.
  # Every read is tagged with the pid it read: a result for another process (the
  # page changed meanwhile) is dropped.

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

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(prev: nil, targets: [], selected: 0, about: nil, sample: nil, relations: nil)
     |> assign(series: empty_series(), sample_timer: nil, relations_timer: nil)}
  end

  @impl Panel
  def handle_reset(_events, socket), do: socket

  @impl Panel
  def handle_events(_events, socket), do: socket

  # A new page, the tab selected or the panel visible again: read now and
  # (re)start polling. Hidden: the timers are not renewed.
  @impl Panel
  def handle_props(%{assigns: assigns} = socket) do
    prev = assigns.prev || %{page: nil, shown?: false, visible?: false}
    socket = assign(socket, :prev, Map.take(assigns, [:page, :shown?, :visible?]))

    cond do
      prev.page != assigns.page -> socket |> retarget(0) |> poll_now()
      not (prev.shown? and prev.visible?) and polling?(socket) -> poll_now(socket)
      true -> socket
    end
  end

  @impl Panel
  def handle_info({:sample, pid}, socket) do
    socket = assign(socket, :sample_timer, nil)

    case current?(socket, pid) and polling?(socket) do
      true -> socket |> read_sample() |> schedule(:sample)
      false -> socket
    end
  end

  def handle_info({:relations, pid}, socket) do
    socket = assign(socket, :relations_timer, nil)

    case current?(socket, pid) and polling?(socket) do
      true -> socket |> read_relations() |> schedule(:relations)
      false -> socket
    end
  end

  def handle_info(_message, socket), do: socket

  @impl Phoenix.LiveComponent
  def handle_event("select", %{"index" => index}, socket) when is_binary(index) do
    case Integer.parse(index) do
      {index, ""} when index >= 0 and index < length(socket.assigns.targets) ->
        {:noreply, socket |> retarget(index) |> poll_now()}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("select", _params, socket), do: {:noreply, socket}

  ## Targets

  # The page's LiveView first, then the other processes of its sids (nested
  # LiveViews), at most @max_targets.
  defp retarget(socket, index) do
    targets = targets(socket.assigns.page)
    pid = Enum.at(targets, index, %{pid: nil}).pid

    socket
    |> cancel_timers()
    |> assign(
      targets: targets,
      selected: index,
      about: pid && ProcessInfo.about(pid),
      sample: nil,
      relations: nil,
      series: empty_series()
    )
  end

  # A pending read of the previous target would otherwise keep a second loop.
  defp cancel_timers(socket) do
    for key <- [:sample_timer, :relations_timer],
        ref = socket.assigns[key],
        do: Process.cancel_timer(ref)

    assign(socket, sample_timer: nil, relations_timer: nil)
  end

  defp targets(%Page{sids: sids}) do
    owners =
      for sid <- Enum.reverse(sids),
          {:ok, %Session{kind: :live_view, owner: owner, view: view}} <- [session(sid)],
          is_pid(owner),
          do: %{pid: owner, label: label(view)}

    nested =
      for sid <- sids,
          pid <- pids_for(sid),
          pid not in Enum.map(owners, & &1.pid),
          do: %{pid: pid, label: "nested LiveView"}

    Enum.take(owners ++ nested, @max_targets)
  end

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

  defp target(socket) do
    case Enum.at(socket.assigns.targets, socket.assigns.selected) do
      %{pid: pid} -> pid
      nil -> nil
    end
  end

  defp current?(socket, pid), do: pid == target(socket)

  ## Polling

  defp polling?(%{assigns: %{shown?: true, visible?: true}}), do: true
  defp polling?(_socket), do: false

  defp config(socket), do: Plugins.Process.config(socket.assigns[:config])

  defp poll_now(socket) do
    case polling?(socket) and target(socket) != nil do
      true ->
        socket
        |> read_sample()
        |> read_relations()
        |> schedule(:sample)
        |> schedule(:relations)

      false ->
        socket
    end
  end

  defp schedule(socket, kind) do
    timer = :"#{kind}_timer"
    pid = target(socket)

    case socket.assigns[timer] do
      nil when is_pid(pid) ->
        every = Map.fetch!(config(socket), :"#{kind}_ms")
        assign(socket, timer, Panel.send_after(__MODULE__, socket.assigns.id, {kind, pid}, every))

      _scheduled_or_none ->
        socket
    end
  end

  defp read_sample(socket) do
    case ProcessInfo.sample(target(socket)) do
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

  defp read_relations(socket),
    do: assign(socket, :relations, ProcessInfo.relations(target(socket)))

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
              selected={index == @selected}
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
        />
        <.vital
          id="pdt-process-queue"
          label="Message queue"
          value={Integer.to_string(@sample.message_queue_len)}
          values={@series.queue}
          warn?={@sample.message_queue_len > 100}
        />
        <.vital
          id="pdt-process-reductions"
          label="Reductions / s"
          value={
            if(@sample.reductions_per_second,
              do: Integer.to_string(@sample.reductions_per_second),
              else: "…"
            )
          }
          values={@series.reductions}
        />
      </div>
      <dl :if={is_map(@sample)} id="pdt-process-details" class="pdt-process__details">
        <dt>status</dt>
        <dd>{@sample.status}</dd>
        <dt>running</dt>
        <dd><code>{@sample.current_function}</code></dd>
        <dt>heap</dt>
        <dd>
          {words(@sample.heap_size)} heap · {words(@sample.total_heap_size)} total · {words(
            @sample.stack_size
          )} stack
        </dd>
        <dt>GC</dt>
        <dd>
          {@sample.minor_gcs} minor collections since the last full sweep · full sweep after {@sample.fullsweep_after}
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

  defp vital(assigns) do
    ~H"""
    <div id={@id} class={["pdt-vital", @warn? && "pdt-vital--warn"]}>
      <span class="pdt-vital__label">{@label}</span>
      <span class="pdt-vital__value">{@value}</span>
      <.sparkline values={@values} label={@label <> " over time"} />
    </div>
    """
  end

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
end
