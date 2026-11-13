defmodule PhoenixDevToolbar.TestPlugins.MountBoomPanel do
  @moduledoc false
  use PhoenixDevToolbar.Panel
  # Raises on purpose: fixture for panel mount crash isolation.
  # Panel wraps mount/1 (defoverridable + super): this clause compiles as the overridable.
  @dialyzer {:nowarn_function, [{:"mount (overridable 1)", 1}]}

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
