defmodule DemoWeb.Endpoint do
  @moduledoc false
  # A minimal host endpoint for LiveView tests of the panel.
  use Phoenix.Endpoint, otp_app: :phoenix_dev_toolbar

  @session_options [store: :cookie, key: "_demo_key", signing_salt: "pdt-test-salt"]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Session, @session_options
  plug DemoWeb.Router
end
