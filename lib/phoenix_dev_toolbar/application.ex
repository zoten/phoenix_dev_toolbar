defmodule PhoenixDevToolbar.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(PhoenixDevToolbar.enabled?()),
      strategy: :one_for_one,
      name: PhoenixDevToolbar.Supervisor
    )
  end

  # Disabled means no processes and no ETS tables at all (ADR 01).
  defp children(false), do: []
  defp children(true), do: [PhoenixDevToolbar.Store]
end
