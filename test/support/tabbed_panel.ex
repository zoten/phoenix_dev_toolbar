defmodule PhoenixDevToolbar.TestPlugins.TabbedPanel do
  @moduledoc false
  use PhoenixDevToolbar.Panel

  @impl Phoenix.LiveComponent
  def mount(socket),
    do:
      {:ok,
       socket
       |> assign(props: 0, navigated: "")
       |> stream_configure(:echoes, dom_id: &"tabbed-#{&1.seq}")}

  @impl PhoenixDevToolbar.Panel
  def handle_reset(events, socket), do: stream(socket, :echoes, events, reset: true)

  @impl PhoenixDevToolbar.Panel
  def handle_events(events, socket),
    do: Enum.reduce(events, socket, &stream_insert(&2, :echoes, &1))

  @impl PhoenixDevToolbar.Panel
  def handle_props(socket), do: update(socket, :props, &(&1 + 1))

  @impl PhoenixDevToolbar.Panel
  def handle_info({:navigate, %{"via" => via}}, socket), do: assign(socket, :navigated, via)
  def handle_info(_message, socket), do: socket

  # Plugin ids are atoms: map the clicked string to a known one.
  @impl Phoenix.LiveComponent
  def handle_event("go", %{"to" => to}, socket) do
    {:noreply, PhoenixDevToolbar.Panel.navigate(socket, target(to), %{"via" => to})}
  end

  defp target("tabbed"), do: :tabbed
  defp target(_other), do: :pdt_test_missing

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div
      id="tabbed"
      data-shown={to_string(@shown?)}
      data-prefix={@config.prefix}
      data-props={@props}
      data-navigated={@navigated}
    >
      <button id="tabbed-go-self" phx-click="go" phx-value-to="tabbed" phx-target={@myself}>go</button>
      <button id="tabbed-go-missing" phx-click="go" phx-value-to="missing" phx-target={@myself}>
        missing
      </button>
      <ul id="tabbed-list" phx-update="stream">
        <li :for={{id, event} <- @streams.echoes} id={id}>{event.data.text}</li>
      </ul>
    </div>
    """
  end
end
