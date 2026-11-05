defmodule PhoenixDevToolbar.TestPlugins.TabbedPanel do
  @moduledoc false
  use PhoenixDevToolbar.Panel

  @impl Phoenix.LiveComponent
  def mount(socket),
    do:
      {:ok, socket |> assign(props: 0) |> stream_configure(:echoes, dom_id: &"tabbed-#{&1.seq}")}

  @impl PhoenixDevToolbar.Panel
  def handle_reset(events, socket), do: stream(socket, :echoes, events, reset: true)

  @impl PhoenixDevToolbar.Panel
  def handle_events(events, socket),
    do: Enum.reduce(events, socket, &stream_insert(&2, :echoes, &1))

  @impl PhoenixDevToolbar.Panel
  def handle_props(socket), do: update(socket, :props, &(&1 + 1))

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="tabbed" data-shown={to_string(@shown?)} data-prefix={@config.prefix} data-props={@props}>
      <ul id="tabbed-list" phx-update="stream">
        <li :for={{id, event} <- @streams.echoes} id={id}>{event.data.text}</li>
      </ul>
    </div>
    """
  end
end
