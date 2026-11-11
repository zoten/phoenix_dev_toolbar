defmodule DemoWeb.HelloPlug do
  @moduledoc false
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts), do: Plug.Conn.send_resp(conn, 200, opts[:greeting])
end
