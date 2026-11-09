defmodule PhoenixDevToolbar.TestPlugins.StrictPanel do
  @moduledoc false
  # A plugin tab written to the guide's letter: handle_info/2 only knows
  # {:navigate, params}. Any other message would raise (and disable the tab).
  use PhoenixDevToolbar.Panel

  @impl PhoenixDevToolbar.Panel
  def handle_reset(_events, socket), do: socket

  @impl PhoenixDevToolbar.Panel
  def handle_events(_events, socket), do: socket

  @impl PhoenixDevToolbar.Panel
  def handle_info({:navigate, _params}, socket), do: socket

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="strict" data-internal={to_string(Map.has_key?(assigns, :pdt_actions))}>strict</div>
    """
  end
end
