defmodule PhoenixDevToolbar.Layouts do
  @moduledoc false
  # Root layout of the panel iframe (ADR 04): our own assets only, nothing from
  # the host. Asset URLs are relative to the panel route, so the toolbar works
  # under any mount path.

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:base, assigns.conn.request_path |> Path.dirname() |> String.trim_trailing("/"))
      |> assign(:socket_path, socket_path(assigns.conn))

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Dev Toolbar</title>
        <link rel="stylesheet" href={@base <> "/assets/panel.css"} />
        <script defer src={@base <> "/assets/panel.js"} data-socket-path={@socket_path}>
        </script>
      </head>
      <body class="pdt">
        {@inner_content}
      </body>
    </html>
    """
  end

  defp socket_path(%Plug.Conn{private: %{phoenix_dev_toolbar_panel: %{live_socket_path: path}}}),
    do: path

  defp socket_path(_conn), do: "/live"
end
