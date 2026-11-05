defmodule DemoWeb.Layouts do
  @moduledoc false
  # The host's root layout: a full document, so the plug can inject the loader.
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
      <head>
        <title>demo</title>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end
