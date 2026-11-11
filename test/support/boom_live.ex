defmodule DemoWeb.BoomLive do
  @moduledoc false
  # A host LiveView that crashes on demand: in a LiveComponent's handle_event,
  # or in its own render.
  use Phoenix.LiveView

  @impl Phoenix.LiveView
  def mount(_params, _session, socket), do: {:ok, assign(socket, broken?: false)}

  @impl Phoenix.LiveView
  def handle_event("break", _params, socket), do: {:noreply, assign(socket, broken?: true)}

  # No clause matches other params: a FunctionClauseError whose top frame
  # carries the call's arguments (params and socket).
  def handle_event("strict", %{"ok" => true}, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div>
      <p id="state">{state(@broken?)}</p>
      <.live_component module={DemoWeb.BoomComponent} id="boom" />
    </div>
    """
  end

  defp state(true), do: raise(ArgumentError, "bad render")
  defp state(false), do: "ok"
end
