defmodule DemoWeb.PageLive do
  @moduledoc false
  # A host application LiveView, outside the toolbar namespace.
  use Phoenix.LiveView

  @impl true
  def render(assigns), do: ~H"<p>page</p>"
end
