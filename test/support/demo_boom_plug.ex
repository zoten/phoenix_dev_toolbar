defmodule DemoWeb.BoomPlug do
  @moduledoc false
  @behaviour Plug
  # Raises on purpose: fixture for the exception banner.
  @dialyzer {:nowarn_function, call: 2}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(_conn, _opts), do: raise(ArgumentError, "boom")
end
