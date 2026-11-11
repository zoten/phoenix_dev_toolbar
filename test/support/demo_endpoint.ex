defmodule DemoWeb.Endpoint do
  @moduledoc false
  # A minimal host endpoint for LiveView tests of the panel. The toolbar plug
  # sits before the session plug, as in a generated endpoint's
  # `code_reloading?` block.
  use Phoenix.Endpoint, otp_app: :phoenix_dev_toolbar

  @session_options [store: :cookie, key: "_demo_key", signing_salt: "pdt-test-salt"]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug PhoenixDevToolbar.Plug

  # As in a generated endpoint (framework noise, ADR 08). Its repos come from
  # an app env only the CheckRepoStatus test sets: a no-op everywhere else.
  if Code.ensure_loaded?(Phoenix.Ecto.CheckRepoStatus) do
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :pdt_check_repo_status
  end

  plug Plug.Session, @session_options
  plug DemoWeb.Router
end
