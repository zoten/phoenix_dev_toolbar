defmodule PhoenixDevToolbar.TestOwnLive do
  @moduledoc false
  # Stands in for the toolbar's own LiveViews (the panel), which are never tracked.
  use Phoenix.LiveView

  @impl Phoenix.LiveView
  def render(assigns), do: ~H"<p>toolbar</p>"
end
