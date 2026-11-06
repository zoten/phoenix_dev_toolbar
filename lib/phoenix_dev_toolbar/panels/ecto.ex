defmodule PhoenixDevToolbar.Panels.Ecto do
  @moduledoc false
  # The Ecto tab (ADR 05, ADR 08): the page's queries, oldest first, with the
  # N+1 groups detected above them. Rows from a group's threshold on are tagged.

  use PhoenixDevToolbar.Panel

  import PhoenixDevToolbar.Components

  alias PhoenixDevToolbar.NPlusOne
  alias PhoenixDevToolbar.Plugins

  # Rows kept in the DOM; the Store keeps 500 events per plugin and session.
  @dom_limit 500

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> stream_configure(:queries, dom_id: &"pdt-query-#{&1.seq}")
     |> assign(n_plus_one: nil, groups: [], detected: 0)}
  end

  @impl PhoenixDevToolbar.Panel
  def handle_reset(events, socket) do
    threshold = Plugins.Ecto.n_plus_one(socket.assigns[:config])
    socket = assign(socket, n_plus_one: NPlusOne.new(threshold), groups: [], detected: 0)

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

    {queries, socket}
  end

  defp mark(event, :ok), do: event
  defp mark(event, _detected), do: %{event | data: Map.put(event.data, :n_plus_one?, true)}

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="pdt-ecto">
      <.n_plus_one_list :if={@detected > 0} groups={@groups} detected={@detected} root={@page.root} />
      <ul id="pdt-queries" class="pdt-list" phx-update="stream">
        <li id="pdt-queries-empty" class="pdt-list__empty">No queries yet.</li>
        <.query_row :for={{id, event} <- @streams.queries} id={id} event={event} root={@page.root} />
      </ul>
    </div>
    """
  end
end
