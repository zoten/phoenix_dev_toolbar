defmodule DemoWeb.BoomPlug do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(_conn, _opts), do: raise(ArgumentError, "boom")
end
