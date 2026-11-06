defmodule PhoenixDevToolbar.OriginEndpoint do
  @moduledoc false
  # A host endpoint whose LiveView socket sets its own `check_origin`, stricter
  # than the endpoint's: the panel socket must apply the socket's (ADR 04).
  use Phoenix.Endpoint, otp_app: :phoenix_dev_toolbar

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [check_origin: ["//allowed.example"], connect_info: [:peer_data]]

  plug PhoenixDevToolbar.Plug
end
