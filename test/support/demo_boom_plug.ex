defmodule DemoWeb.BoomPlug do
  @moduledoc false
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(_conn, _opts), do: raise(ArgumentError, "boom")
end
