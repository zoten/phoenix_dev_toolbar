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

  def handle_event("async", _params, socket),
    do: {:noreply, start_async(socket, :boom, fn -> :done end)}

  @impl Phoenix.LiveComponent
  def handle_async(:boom, _result, _socket), do: raise("async boom")

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="fragile">
      <button id="fragile-explode" phx-click="explode" phx-target={@myself}>explode</button>
      <button id="fragile-async" phx-click="async" phx-target={@myself}>async</button>
      <span :for={value <- @values} class="fragile-value">{render_value(value)}</span>
    </div>
    """
  end

  defp render_value("render"), do: raise("render boom")
  defp render_value(value), do: value
end
