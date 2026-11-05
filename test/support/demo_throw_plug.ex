defmodule DemoWeb.ThrowPlug do
  @moduledoc false
  # Throws a huge term, to check the exception banner stays bounded.
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(_conn, _opts), do: throw(Enum.to_list(1..100_000))
end
