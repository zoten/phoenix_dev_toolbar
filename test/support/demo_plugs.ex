defmodule DemoWeb.HelloPlug do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts), do: Plug.Conn.send_resp(conn, 200, opts[:greeting])
end
