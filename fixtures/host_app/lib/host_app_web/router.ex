defmodule HostApp.Router do
  # The toolbar needs nothing here: PhoenixDevToolbar.Plug serves the panel.
  use Phoenix.Router

  pipeline :browser do
    plug :fetch_session
    plug :protect_from_forgery
  end
end
