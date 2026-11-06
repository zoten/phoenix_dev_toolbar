defmodule DemoWeb.Router do
  @moduledoc false
  # A real Phoenix router, so tests see the exact router_dispatch telemetry and
  # can drive a host LiveView end to end. The toolbar needs no routes:
  # PhoenixDevToolbar.Plug serves it.
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :fetch_session
    plug :put_root_layout, html: {DemoWeb.Layouts, :root}
  end

  get "/hello/:name", DemoWeb.HelloPlug, greeting: "hi"
  get "/boom", DemoWeb.BoomPlug, []
  get "/throw", DemoWeb.ThrowPlug, []
  get "/big-opts", DemoWeb.HelloPlug, greeting: "hi", payload: Enum.to_list(1..10_000)

  scope "/" do
    pipe_through :browser

    live_session :demo do
      live "/demo", DemoWeb.PageLive
      live "/demo/other", DemoWeb.PageLive
      live "/demo/components", DemoWeb.ComponentsLive
      live "/demo/nested", DemoWeb.NestedLive
    end
  end
end
