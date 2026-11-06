defmodule DemoWeb.NestedLive do
  @moduledoc false
  # A host LiveView rendering another one (a nested LiveView shares its
  # parent's sid): for the Process tab's process list.
  use Phoenix.LiveView

  @impl Phoenix.LiveView
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div>{live_render(@socket, DemoWeb.PageLive, id: "nested-child")}</div>
    """
  end
end
