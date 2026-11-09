defmodule PhoenixDevToolbar.SofoSupervisor do
  @moduledoc false
  # A :simple_one_for_one supervisor of Agents: one spec, any number of children.
  @behaviour :supervisor

  @impl :supervisor
  def init(:ok) do
    child = %{id: :agent, start: {Agent, :start_link, [fn -> :ok end]}}
    {:ok, {%{strategy: :simple_one_for_one}, [child]}}
  end
end
