defmodule PhoenixDevToolbar.Panels.Request do
  @moduledoc false
  # The Request tab (ADR 05): router dispatches, exceptions and the response.

  use PhoenixDevToolbar.Panel

  import PhoenixDevToolbar.Components

  @dom_limit 500

  @impl Phoenix.LiveComponent
  def mount(socket),
    do: {:ok, stream_configure(socket, :requests, dom_id: &"pdt-request-#{&1.seq}")}

  @impl PhoenixDevToolbar.Panel
  def handle_reset(events, socket),
    do: stream(socket, :requests, events, reset: true, limit: -@dom_limit)

  @impl PhoenixDevToolbar.Panel
  def handle_events(events, socket),
    do: Enum.reduce(events, socket, &stream_insert(&2, :requests, &1, limit: -@dom_limit))

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <ul id="pdt-requests" class="pdt-list" phx-update="stream">
      <li id="pdt-requests-empty" class="pdt-list__empty">No requests yet.</li>
      <.request_row :for={{id, event} <- @streams.requests} id={id} event={event} />
    </ul>
    """
  end
end
