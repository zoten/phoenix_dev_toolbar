defmodule DemoWeb.CounterComponent do
  @moduledoc false
  use Phoenix.LiveComponent

  @impl true
  def mount(socket), do: {:ok, assign(socket, count: 0)}

  @impl true
  def handle_event("inc", _params, socket), do: {:noreply, update(socket, :count, &(&1 + 1))}

  @impl true
  def render(assigns) do
    ~H"""
    <button id="counter-inc" phx-click="inc" phx-target={@myself}>{@count}</button>
    """
  end
end
