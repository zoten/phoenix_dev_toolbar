defmodule DemoWeb.PersonaPlug do
  @moduledoc false
  # Stands for a host's auth plug: assigns `:persona` from the `x-persona`
  # request header, so `label:` can read `conn.assigns[:persona]`.
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "x-persona") do
      [persona] -> Plug.Conn.assign(conn, :persona, persona)
      _none -> conn
    end
  end
end
