defmodule PhoenixDevToolbar.TestPlugins.FragilePanel do
  @moduledoc false
  use PhoenixDevToolbar.Panel

  @impl Phoenix.LiveComponent
  def mount(socket), do: {:ok, assign(socket, :values, [])}

  @impl PhoenixDevToolbar.Panel
  def handle_reset(events, socket), do: assign(socket, :values, Enum.map(events, & &1.data.value))

  @impl PhoenixDevToolbar.Panel
  def handle_events(events, socket) do
    case Enum.find(events, &(&1.data.value == "panel")) do
      nil -> update(socket, :values, &(&1 ++ Enum.map(events, fn e -> e.data.value end)))
      _boom -> raise "panel boom"
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("explode", _params, _socket), do: raise("click boom")

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="fragile">
      <button id="fragile-explode" phx-click="explode" phx-target={@myself}>explode</button>
      <span :for={value <- @values} class="fragile-value">{value}</span>
    </div>
    """
  end
end
