defmodule PhoenixDevToolbar.Layouts do
  @moduledoc false
  # Root layout of the panel iframe (ADR 04): our own assets only, nothing from
  # the host. Asset URLs come from the plug's configured `:path`, never from the
  # request path: `//__pdt/panel` routes to the panel too, and a base derived
  # from it would load script from another host (`//__pdt/...`).

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    %{path: base} = assigns.conn.private.phoenix_dev_toolbar_panel
    assigns = assign(assigns, base: base)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Dev Toolbar</title>
        <link rel="stylesheet" href={@base <> "/assets/panel.css"} />
        <%!-- The host's own Phoenix and LiveView clients, then our glue: deferred
             scripts run in document order. --%>
        <script defer src={@base <> "/assets/phoenix.js"}>
        </script>
        <script defer src={@base <> "/assets/live_view.js"}>
        </script>
        <%!-- The panel's own socket (ADR 04, PhoenixDevToolbar.PanelSocket). --%>
        <script defer src={@base <> "/assets/panel.js"} data-socket-path={@base <> "/live"}>
        </script>
      </head>
      <body class="pdt">
        {@inner_content}
      </body>
    </html>
    """
  end
end
