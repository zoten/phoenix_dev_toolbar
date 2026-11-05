defmodule PhoenixDevToolbar.Panels.Ecto do
  @moduledoc false
  # The Ecto tab (ADR 05): the page's queries, oldest first.

  use PhoenixDevToolbar.Panel

  import PhoenixDevToolbar.Components

  # Rows kept in the DOM; the Store keeps 500 events per plugin and page.
  @dom_limit 500

  @impl Phoenix.LiveComponent
  def mount(socket), do: {:ok, stream_configure(socket, :queries, dom_id: &"pdt-query-#{&1.seq}")}

  @impl PhoenixDevToolbar.Panel
  def handle_reset(events, socket),
    do: stream(socket, :queries, Enum.filter(events, &query?/1), reset: true, limit: -@dom_limit)

  @impl PhoenixDevToolbar.Panel
  def handle_events(events, socket) do
    events
    |> Enum.filter(&query?/1)
    |> Enum.reduce(socket, &stream_insert(&2, :queries, &1, limit: -@dom_limit))
  end

  defp query?(event), do: event.kind == :query

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <ul id="pdt-queries" class="pdt-list" phx-update="stream">
      <li id="pdt-queries-empty" class="pdt-list__empty">No queries yet.</li>
      <.query_row :for={{id, event} <- @streams.queries} id={id} event={event} root={@page.root} />
    </ul>
    """
  end
end
