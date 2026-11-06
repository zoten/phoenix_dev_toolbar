defmodule PhoenixDevToolbar.Panels.Ecto do
  @moduledoc false
  # The Ecto tab (ADR 05, ADR 08): the page's queries, oldest first, with the
  # N+1 groups detected above them. Rows from a group's threshold on are tagged.
  # A SELECT with captured params has an EXPLAIN button: the browser sends only
  # its seq, the query is read back from the Store (this page's sids only) and
  # explained in start_async, one at a time; the plan replaces the row.

  use PhoenixDevToolbar.Panel

  import PhoenixDevToolbar.Components

  alias PhoenixDevToolbar.Explain
  alias PhoenixDevToolbar.NPlusOne
  alias PhoenixDevToolbar.Plugins
  alias PhoenixDevToolbar.Store

  # Rows kept in the DOM; the Store keeps 500 events per plugin and session.
  @dom_limit 500

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> stream_configure(:queries, dom_id: &"pdt-query-#{&1.seq}")
     |> assign(n_plus_one: nil, groups: [], detected: 0, flagged: MapSet.new(), explaining: nil)}
  end

  @impl PhoenixDevToolbar.Panel
  def handle_reset(events, socket) do
    threshold = Plugins.Ecto.n_plus_one(socket.assigns[:config])

    socket =
      assign(socket,
        n_plus_one: NPlusOne.new(threshold),
        groups: [],
        detected: 0,
        flagged: MapSet.new(),
        explaining: nil
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
    {queries, n_plus_one} =
      events
      |> Enum.filter(&(&1.kind == :query))
      |> Enum.map_reduce(socket.assigns.n_plus_one, fn event, state ->
        {state, result} = NPlusOne.add(state, event)
        {mark(event, result), state}
      end)

    socket =
      socket
      |> assign(:n_plus_one, n_plus_one)
      |> assign(:groups, NPlusOne.groups(n_plus_one))
      |> assign(:detected, NPlusOne.detected(n_plus_one))
      |> update(:flagged, &flag(&1, queries))

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

  @impl Phoenix.LiveComponent
  def handle_event("explain", %{"seq" => seq}, socket) do
    with nil <- socket.assigns.explaining,
         {seq, ""} <- Integer.parse(to_string(seq)),
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

  @impl Phoenix.LiveComponent
  def handle_async(:explain, {:ok, {seq, result}}, socket) do
    socket = assign(socket, :explaining, nil)

    case find(socket, seq) do
      nil -> {:noreply, socket}
      event -> {:noreply, show_plan(socket, event, result)}
    end
  end

  def handle_async(:explain, {:exit, reason}, socket) do
    seq = socket.assigns.explaining
    socket = assign(socket, :explaining, nil)

    case seq && find(socket, seq) do
      nil -> {:noreply, socket}
      event -> {:noreply, show_plan(socket, event, {:error, inspect(reason, limit: 5)})}
    end
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
    data =
      event.data
      |> Map.put(:plan, plan)
      |> Map.put(:n_plus_one?, MapSet.member?(socket.assigns.flagged, event.seq))

    stream_insert(socket, :queries, %{event | data: data}, limit: -@dom_limit)
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="pdt-ecto">
      <.n_plus_one_list :if={@detected > 0} groups={@groups} detected={@detected} root={@page.root} />
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
end
