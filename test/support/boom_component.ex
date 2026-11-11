defmodule DemoWeb.BoomComponent do
  @moduledoc false
  use Phoenix.LiveComponent

  @impl Phoenix.LiveComponent
  def handle_event("boom", _params, socket) do
    # Always true: keeps Dialyzer from inferring a function that never returns.
    if socket.assigns.myself, do: raise(ArgumentError, "bad component event")
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <button id="boom-component" phx-click="boom" phx-target={@myself}>boom</button>
    """
  end
end
