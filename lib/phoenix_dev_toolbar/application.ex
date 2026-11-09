defmodule PhoenixDevToolbar.Application do
  @moduledoc false

  use Application

  require Logger

  alias PhoenixDevToolbar.ClientPolicy
  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Config

  @impl Application
  def start(_type, _args) do
    :ok = settle_enabled(Application.fetch_env(:phoenix_dev_toolbar, :enabled), mix_loaded?())
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

  @impl Application
  def prep_stop(state) do
    Collector.detach()
    state
  end

  @doc false
  @spec plugins() :: [Config.entry()]
  def plugins, do: Config.plugins()

  @doc false
  # Running without Mix means a release: the package was installed without
  # `only: :dev`. Turn off unless `enabled` was set explicitly (ADR 01).
  @spec settle_enabled({:ok, term()} | :error, boolean()) :: :ok
  def settle_enabled({:ok, _explicit}, _mix_loaded?), do: :ok
  def settle_enabled(:error, true), do: :ok

  def settle_enabled(:error, false) do
    Application.put_env(:phoenix_dev_toolbar, :enabled, false)

    Logger.warning(
      "[phoenix_dev_toolbar] running outside Mix (a release?): the toolbar is disabled. " <>
        "Declare the dependency with `only: :dev`, or set `enabled: true` to force it."
    )
  end

  defp mix_loaded?, do: Code.ensure_loaded?(Mix)

  # Disabled means no processes, no ETS tables and no handlers (ADR 01).
  defp children(false), do: []
  defp children(true), do: [PhoenixDevToolbar.Store, PhoenixDevToolbar.Notify]

  defp maybe_attach(false), do: :ok

  defp maybe_attach(true) do
    ClientPolicy.warn_config()
    Collector.attach(plugins())
  end
end
