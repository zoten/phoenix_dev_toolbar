defmodule DemoWeb.Router do
  @moduledoc false
  # A real Phoenix router, so tests see the exact router_dispatch telemetry.
  use Phoenix.Router

  get "/hello/:name", DemoWeb.HelloPlug, greeting: "hi"
  get "/boom", DemoWeb.BoomPlug, []
end
