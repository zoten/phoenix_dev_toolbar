defmodule PhoenixDevToolbar.TestPlugins.MountBoomPanel do
  @moduledoc false
  use PhoenixDevToolbar.Panel

  @impl Phoenix.LiveComponent
  def mount(_socket), do: raise("mount boom")

  @impl PhoenixDevToolbar.Panel
  def handle_reset(_events, socket), do: socket

  @impl PhoenixDevToolbar.Panel
  def handle_events(_events, socket), do: socket

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="mount-boom"></div>
    """
  end
end
