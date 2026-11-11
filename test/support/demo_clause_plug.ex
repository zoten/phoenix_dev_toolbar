defmodule DemoWeb.ClausePlug do
  @moduledoc false
  # Crashes with a FunctionClauseError whose top frame carries the call's
  # arguments, a conn and its params among them.
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: apply(__MODULE__, :strict, [conn, %{"password" => "hunter2"}])

  @doc false
  def strict(%{never: true}, _params), do: :ok
end
