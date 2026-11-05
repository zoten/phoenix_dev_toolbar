defmodule PhoenixDevToolbar.Layouts do
  @moduledoc false
  # Root layout of the panel iframe (ADR 04): our own assets only, nothing from
  # the host. Asset URLs come from the plug's configured `:path`, never from the
  # request path: `//__pdt/panel` routes to the panel too, and a base derived
  # from it would load script from another host (`//__pdt/...`).

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    %{path: base, live_socket_path: socket_path} = assigns.conn.private.phoenix_dev_toolbar_panel
    assigns = assign(assigns, base: base, socket_path: socket_path)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Dev Toolbar</title>
        <link rel="stylesheet" href={@base <> "/assets/panel.css"} />
        <%!-- The host's own Phoenix and LiveView clients, then our glue: deferred
             scripts run in document order. --%>
        <script defer src={@base <> "/assets/phoenix.js"}>
        </script>
        <script defer src={@base <> "/assets/live_view.js"}>
        </script>
        <script defer src={@base <> "/assets/panel.js"} data-socket-path={@socket_path}>
        </script>
      </head>
      <body class="pdt">
        {@inner_content}
      </body>
    </html>
    """
  end
end
