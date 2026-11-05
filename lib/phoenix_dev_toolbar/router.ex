defmodule PhoenixDevToolbar.Router do
  @moduledoc """
  Mounts the toolbar panel in your router.

      if Application.compile_env(:my_app, :dev_routes) do
        import PhoenixDevToolbar.Router

        scope "/" do
          pipe_through :browser
          dev_toolbar "/__pdt"
        end
      end

  Use the same path as the `:path` option of `PhoenixDevToolbar.Plug`
  (default `"/__pdt"`, which is also the default here).

  ## Options

    * `:live_socket_path` - the path of your `Phoenix.LiveView.Socket`, as
      declared in your endpoint. Defaults to `"/live"`.
  """

  @doc """
  Defines the toolbar routes under `path` (default `"/__pdt"`).

  The panel runs in its own `live_session` with its own root layout, so it
  never inherits your layouts, assets or `on_mount` hooks.
  """
  defmacro dev_toolbar(path \\ "/__pdt", opts \\ []) do
    quote bind_quoted: [path: path, opts: opts] do
      scope path, alias: false, as: false do
        import Phoenix.LiveView.Router, only: [live: 4, live_session: 3]

        live_session :phoenix_dev_toolbar, root_layout: {PhoenixDevToolbar.Layouts, :root} do
          live "/panel", PhoenixDevToolbar.PanelLive, :panel,
            as: :phoenix_dev_toolbar_panel,
            private: %{
              phoenix_dev_toolbar: %{
                live_socket_path: Keyword.get(opts, :live_socket_path, "/live")
              }
            }
        end
      end
    end
  end
end
