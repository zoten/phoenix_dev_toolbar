defmodule DemoWeb.CounterComponent do
  @moduledoc false
  use Phoenix.LiveComponent

  @impl Phoenix.LiveComponent
  def mount(socket), do: {:ok, assign(socket, count: 0)}

  @impl Phoenix.LiveComponent
  def handle_event("inc", _params, socket), do: {:noreply, update(socket, :count, &(&1 + 1))}

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <button id="counter-inc" phx-click="inc" phx-target={@myself}>{@count}</button>
    """
  end
end
