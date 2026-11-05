defmodule DemoWeb.Router do
  @moduledoc false
  # A real Phoenix router, so tests see the exact router_dispatch telemetry and
  # mount the toolbar the way a host app does.
  use Phoenix.Router

  import PhoenixDevToolbar.Router

  pipeline :browser do
    plug :fetch_session
    plug :protect_from_forgery
  end

  get "/hello/:name", DemoWeb.HelloPlug, greeting: "hi"
  get "/boom", DemoWeb.BoomPlug, []

  scope "/" do
    pipe_through :browser
    dev_toolbar "/__pdt"
  end
end
