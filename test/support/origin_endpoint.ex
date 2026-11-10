defmodule PhoenixDevToolbar.OriginEndpoint do
  @moduledoc false
  # A host endpoint whose LiveView socket sets `check_origin: false`, as
  # generated Phoenix dev configs do: the panel socket enforces its own
  # same origin rule regardless (ADR 04).
  use Phoenix.Endpoint, otp_app: :phoenix_dev_toolbar

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [check_origin: false, connect_info: [:peer_data]]

  plug PhoenixDevToolbar.Plug
end
