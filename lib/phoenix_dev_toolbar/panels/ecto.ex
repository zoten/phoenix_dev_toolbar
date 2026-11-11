defmodule PhoenixDevToolbar.Panels.Ecto do
  @moduledoc false
  # The Ecto tab (ADR 05, ADR 08): the page's queries, oldest first, with the
  # N+1 groups detected above them. Rows from a group's threshold on are tagged.
  # A SELECT with captured params has an EXPLAIN button: the browser sends only
  # its seq, the query is read back from the Store (this page's sids only) and
  # explained in start_async, one at a time; the plan replaces the row.
  # Export (EctoExport): Download is a same-origin link the plug answers; Copy
  # pushes the JSON to the PdtExport hook, built in start_async since a full
  # export may run EXPLAINs. One EXPLAIN or copy at a time.

  use PhoenixDevToolbar.Panel

  import PhoenixDevToolbar.Components

  alias PhoenixDevToolbar.EctoExport
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Explain
  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.NPlusOne
  alias PhoenixDevToolbar.Plugins
  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.Truncate

  # Rows kept in the DOM; the Store keeps 500 events per plugin and session.
  @dom_limit 500
  # Expanded rows and EXPLAIN plans kept beside the stream (rows render their
  # details only when open, ADR 04): the newest seqs win.
  @side_limit 50

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> stream_configure(:queries, dom_id: &"pdt-query-#{&1.seq}")
     |> assign(
       n_plus_one: nil,
       groups: [],
       detected: 0,
       flagged: MapSet.new(),
       shown: :queue.new(),
       open: MapSet.new(),
       plans: %{},
       explaining: nil,
       exporting: nil,
       queries?: false,
       export_choice: %{format: "short", explain?: false}
     )}
  end

  @impl PhoenixDevToolbar.Panel
  def handle_reset(events, socket) do
    threshold = Plugins.Ecto.n_plus_one(socket.assigns[:config])

    # A new page: an EXPLAIN still running is stopped, so it never holds a
    # pool connection past its page (the task's exit rolls it back).
    socket =
      socket
      |> cancel_explain()
      |> cancel_export()
      |> assign(
        n_plus_one: NPlusOne.new(threshold),
        groups: [],
        detected: 0,
        flagged: MapSet.new(),
        shown: :queue.new(),
        open: MapSet.new(),
        plans: %{},
        explaining: nil,
        exporting: nil,
        queries?: false
      )

    {queries, socket} = detect(events, socket)
    stream(socket, :queries, queries, reset: true, limit: -@dom_limit)
  end

  @impl PhoenixDevToolbar.Panel
  def handle_events(events, socket) do
    {queries, socket} = detect(events, socket)
    Enum.reduce(queries, socket, &stream_insert(&2, :queries, &1, limit: -@dom_limit))
  end

  # Folds the queries into the detector; a query at or past its group's
  # threshold is marked for its row. The detector itself changes on every
  # query: only its groups are rendered, assigned apart so the list re-renders
  # when they change.
  defp detect(events, socket) do
    # Every event goes through the detector (a Clear marker resets it); only
    # queries become rows.
    {marked, n_plus_one} =
      Enum.map_reduce(events, socket.assigns.n_plus_one, fn event, state ->
        {state, result} = NPlusOne.add(state, event)
        {mark(event, result), state}
      end)

    queries = Enum.filter(marked, &(&1.kind == :query))

    socket =
      socket
      |> assign(:n_plus_one, n_plus_one)
      |> assign(:groups, NPlusOne.groups(n_plus_one))
      |> assign(:detected, NPlusOne.detected(n_plus_one))
      |> update(:flagged, &flag(&1, queries))
      |> update(:shown, &show(&1, queries))
      |> update(:queries?, &(&1 or queries != []))

    {queries, socket}
  end

  defp mark(event, :ok), do: event
  defp mark(event, _detected), do: %{event | data: Map.put(event.data, :n_plus_one?, true)}

  # The seqs of tagged rows, so a row re-rendered with its plan keeps its tag.
  # Bounded like the DOM: the oldest past @dom_limit are dropped.
  defp flag(flagged, queries) do
    flagged =
      for %{seq: seq, data: %{n_plus_one?: true}} <- queries, reduce: flagged do
        acc -> MapSet.put(acc, seq)
      end

    case MapSet.size(flagged) > @dom_limit do
      true -> flagged |> Enum.sort() |> Enum.take(-@dom_limit) |> MapSet.new()
      false -> flagged
    end
  end

  # The seqs of the rows in the DOM, oldest first, like the stream's limit: a
  # late EXPLAIN result for a row that left never brings it back.
  defp show(shown, queries) do
    shown = Enum.reduce(queries, shown, &:queue.in(&1.seq, &2))

    case :queue.len(shown) - @dom_limit do
      over when over > 0 -> elem(:queue.split(over, shown), 1)
      _within -> shown
    end
  end

  defp shown?(socket, seq), do: :queue.member(seq, socket.assigns.shown)

  @impl Phoenix.LiveComponent
  def handle_event("explain", %{"seq" => seq}, socket) do
    with nil <- socket.assigns.explaining,
         nil <- socket.assigns.exporting,
         true <- is_binary(seq),
         {seq, ""} <- Integer.parse(seq),
         %{} = event <- find(socket, seq) do
      repos = Map.get(socket.assigns.config || %{}, :repos, [])

      {:noreply,
       socket
       |> assign(:explaining, seq)
       |> show_plan(event, :running)
       |> start_async(:explain, fn -> {seq, Explain.run(event, repos)} end)}
    else
      _busy_or_unknown -> {:noreply, socket}
    end
  end

  def handle_event("explain", _params, socket), do: {:noreply, socket}

  # The form's choices, kept so a re-render (an export, a new query) shows
  # them instead of the defaults. Kept across pages.
  def handle_event("export_form", params, socket) do
    case export_format(params["format"]) do
      {:ok, format} ->
        choice = %{format: Atom.to_string(format), explain?: params["explain"] == "true"}
        {:noreply, assign(socket, :export_choice, choice)}

      :error ->
        {:noreply, socket}
    end
  end

  # Fixed strings only: never an atom from the client. A Copy refused while
  # busy (Copy is disabled then, but a click can race the render) still
  # answers the hook, which started a clipboard write in the click.
  def handle_event("export", params, socket) do
    with {:ok, format} <- export_format(params["format"]),
         "copy" <- params["action"] do
      export(socket, format, params["explain"] == "true")
    else
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("hide_plan", %{"seq" => seq}, socket) when is_binary(seq) do
    with {seq, ""} <- Integer.parse(seq),
         true <- seq != socket.assigns.explaining and shown?(socket, seq),
         %{} = event <- find(socket, seq) do
      {:noreply, show_plan(socket, event, nil)}
    else
      _unknown -> {:noreply, socket}
    end
  end

  def handle_event("toggle_details", %{"seq" => seq}, socket) when is_binary(seq) do
    with {seq, ""} <- Integer.parse(seq),
         true <- shown?(socket, seq),
         %{} = event <- find(socket, seq) do
      open = socket.assigns.open

      open =
        case MapSet.member?(open, seq) do
          true -> MapSet.delete(open, seq)
          false -> open |> MapSet.put(seq) |> newest(@side_limit)
        end

      {:noreply, socket |> assign(:open, open) |> insert_row(event)}
    else
      _unknown -> {:noreply, socket}
    end
  end

  def handle_event("toggle_details", _params, socket), do: {:noreply, socket}

  def handle_event("hide_plan", _params, socket), do: {:noreply, socket}

  # Clear is an event in the Store (ADR 08): the Ecto summary (the badge) and
  # this tab fold it like any other, and a page re-read keeps it.
  def handle_event("clear_n_plus_one", _params, socket) do
    case List.last(socket.assigns.page.sids) do
      nil ->
        {:noreply, socket}

      sid ->
        _ = Store.insert(sid, Event.new(:ecto, :n_plus_one_cleared, %{}))
        Notify.event(sid)
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_async(:explain, {:ok, {seq, result}}, socket) do
    socket = assign(socket, :explaining, nil)

    case shown?(socket, seq) && find(socket, seq) do
      %{} = event -> {:noreply, show_plan(socket, event, result)}
      _gone -> {:noreply, socket}
    end
  end

  def handle_async(:explain, {:exit, reason}, socket) do
    seq = socket.assigns.explaining
    socket = assign(socket, :explaining, nil)

    case seq && shown?(socket, seq) && find(socket, seq) do
      %{} = event ->
        {:noreply, show_plan(socket, event, {:error, Truncate.inspect_value(reason)})}

      _gone ->
        {:noreply, socket}
    end
  end

  # `page` is the page the export was built from: the hook drops an export
  # whose page is no longer the form's (the LiveView joined meanwhile).
  def handle_async(:export, {:ok, {page, payload}}, socket) do
    {:noreply,
     socket
     |> assign(:exporting, nil)
     |> push_event("pdt:export", %{payload: payload, page: page})}
  end

  # A page change cancels the export: the hook already dropped its copy.
  def handle_async(:export, {:exit, {:shutdown, :cancel}}, socket),
    do: {:noreply, assign(socket, :exporting, nil)}

  def handle_async(:export, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:exporting, nil)
     |> export_failed("the export crashed: " <> Truncate.inspect_value(reason))}
  end

  defp export(%{assigns: %{explaining: nil, exporting: nil}} = socket, format, explain?) do
    page = Map.take(socket.assigns.page, [:root, :sids, :path])
    config = socket.assigns.config

    {:noreply,
     socket
     |> assign(:exporting, format)
     |> start_async(:export, fn ->
       {page_key(page), EctoExport.page(page, format, explain?, config)}
     end)}
  end

  defp export(socket, _format, _explain?),
    do: {:noreply, export_failed(socket, "the tab is busy, try again in a moment")}

  defp export_failed(socket, reason),
    do: push_event(socket, "pdt:export", %{error: reason, page: page_key(socket.assigns.page)})

  defp cancel_explain(%{assigns: %{explaining: nil}} = socket), do: socket
  defp cancel_explain(socket), do: cancel_async(socket, :explain)

  defp cancel_export(%{assigns: %{exporting: nil}} = socket), do: socket
  defp cancel_export(socket), do: cancel_async(socket, :export)

  defp export_format("short"), do: {:ok, :short}
  defp export_format("full"), do: {:ok, :full}
  defp export_format(_other), do: :error

  # The page an export is built from, as the hook compares it.
  defp page_key(page), do: Enum.join(page.sids, ",")

  # Relative to the panel's URL (<path>/panel): <path>/export/ecto.json.
  defp download_href(page, %{format: format, explain?: explain?}) do
    "export/ecto.json?" <>
      URI.encode_query(%{
        "format" => format,
        "explain" => to_string(explain? and format == "full"),
        "root" => page.root,
        "sids" => Enum.join(page.sids, ",")
      })
  end

  # Only this page's sids: a seq from another page is not found.
  defp find(socket, seq) do
    Enum.find_value(socket.assigns.page.sids, fn sid ->
      case Store.event(sid, seq) do
        %{plugin: :ecto, kind: :query} = event -> event
        _other -> nil
      end
    end)
  end

  defp show_plan(socket, event, plan) do
    plans =
      case plan do
        nil -> Map.delete(socket.assigns.plans, event.seq)
        plan -> socket.assigns.plans |> Map.put(event.seq, plan) |> newest_plans()
      end

    socket |> assign(:plans, plans) |> insert_row(event)
  end

  # Re-renders a row from the Store's event plus what the component keeps for
  # it: its plan, its N+1 tag and whether its details are open.
  defp insert_row(socket, event) do
    %{plans: plans, flagged: flagged, open: open} = socket.assigns

    data =
      event.data
      |> Map.put(:n_plus_one?, MapSet.member?(flagged, event.seq))
      |> Map.put(:open?, MapSet.member?(open, event.seq))
      |> put_plan(Map.get(plans, event.seq))

    stream_insert(socket, :queries, %{event | data: data}, limit: -@dom_limit)
  end

  defp put_plan(data, nil), do: Map.delete(data, :plan)
  defp put_plan(data, plan), do: Map.put(data, :plan, plan)

  defp newest(set, limit) do
    case MapSet.size(set) > limit do
      true -> set |> Enum.sort() |> Enum.take(-limit) |> MapSet.new()
      false -> set
    end
  end

  defp newest_plans(plans) do
    case map_size(plans) > @side_limit do
      true -> plans |> Map.take(plans |> Map.keys() |> Enum.sort() |> Enum.take(-@side_limit))
      false -> plans
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="pdt-ecto">
      <.n_plus_one_list
        :if={@detected > 0}
        groups={@groups}
        detected={@detected}
        root={@page.root}
        target={@myself}
      />
      <.export_form
        :if={@queries?}
        exporting={@exporting != nil}
        busy={@exporting != nil or @explaining != nil}
        choice={@export_choice}
        href={download_href(@page, @export_choice)}
        page={page_key(@page)}
        target={@myself}
      />
      <ul id="pdt-queries" class="pdt-list" phx-update="stream">
        <li id="pdt-queries-empty" class="pdt-list__empty">No queries yet.</li>
        <.query_row
          :for={{id, event} <- @streams.queries}
          id={id}
          event={event}
          root={@page.root}
          target={@myself}
        />
      </ul>
    </div>
    """
  end

  attr :exporting, :boolean, required: true
  attr :busy, :boolean, required: true, doc: "an export or an EXPLAIN is running"
  attr :href, :string, required: true, doc: "the Download link, relative to the panel"
  attr :choice, :map, required: true, doc: "%{format: \"short\" | \"full\", explain?: boolean}"
  attr :page, :string, required: true, doc: "the page's sids, comma separated"
  attr :target, :any, required: true

  defp export_form(assigns) do
    ~H"""
    <form
      id="pdt-ecto-export"
      class="pdt-export"
      phx-change="export_form"
      phx-submit="export"
      phx-target={@target}
      phx-hook="PdtExport"
      data-pdt-page={@page}
      aria-label="Export queries as JSON"
    >
      <span class="pdt-export__label">Export JSON</span>
      <label>
        <input
          id="pdt-export-short"
          type="radio"
          name="format"
          value="short"
          checked={@choice.format == "short"}
        /> short
      </label>
      <label title="Every captured detail, N+1 tags and timings">
        <input
          id="pdt-export-full"
          type="radio"
          name="format"
          value="full"
          checked={@choice.format == "full"}
        /> full
      </label>
      <label title="Full export only: runs EXPLAIN for up to 50 SELECTs (15 s at most)">
        <input
          id="pdt-export-explain"
          type="checkbox"
          name="explain"
          value="true"
          checked={@choice.explain?}
        /> with EXPLAIN
      </label>
      <a id="pdt-export-download" href={@href} download class="pdt-button pdt-button--small">
        Download
      </a>
      <button
        id="pdt-export-copy"
        type="submit"
        name="action"
        value="copy"
        class="pdt-button pdt-button--small"
        disabled={@busy}
        aria-busy={to_string(@busy)}
      >
        Copy
      </button>
      <span id="pdt-export-status" class="pdt-hint" aria-live="polite">
        {if(@exporting, do: "exporting…", else: "")}
      </span>
      <span id="pdt-export-result" class="pdt-hint" phx-update="ignore" aria-live="polite"></span>
    </form>
    """
  end
end
