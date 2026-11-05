defmodule HostApp.Endpoint do
  use Phoenix.Endpoint, otp_app: :host_app

  socket "/live", Phoenix.LiveView.Socket

  if code_reloading? do
    plug PhoenixDevToolbar.Plug
  end

  plug HostApp.Router
end
