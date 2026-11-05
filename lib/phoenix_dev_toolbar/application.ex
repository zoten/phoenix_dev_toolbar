defmodule PhoenixDevToolbar.Application do
  @moduledoc false

  use Application

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Plugins

  # `:defaults` expansion and plugin options arrive with the public API (ADR 05).
  @default_plugins [Plugins.Request, Plugins.Ecto]

  @impl true
  def start(_type, _args) do
    enabled? = PhoenixDevToolbar.enabled?()

    with {:ok, pid} <-
           Supervisor.start_link(children(enabled?),
             strategy: :one_for_one,
             name: PhoenixDevToolbar.Supervisor
           ) do
      maybe_attach(enabled?)
      {:ok, pid}
    end
  end

  @impl true
  def prep_stop(state) do
    Collector.detach()
    state
  end

  @doc false
  @spec plugins() :: [module()]
  def plugins, do: Application.get_env(:phoenix_dev_toolbar, :plugins, @default_plugins)

  # Disabled means no processes, no ETS tables and no handlers (ADR 01).
  defp children(false), do: []
  defp children(true), do: [PhoenixDevToolbar.Store, PhoenixDevToolbar.Notify]

  defp maybe_attach(false), do: :ok
  defp maybe_attach(true), do: Collector.attach(plugins())
end
