defmodule PhoenixDevToolbar.Application do
  @moduledoc false

  use Application

  require Logger

  alias PhoenixDevToolbar.ClientPolicy
  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Config

  @impl Application
  def start(_type, _args) do
    :ok = settle_enabled(Application.fetch_env(:phoenix_dev_toolbar, :enabled), mix_env())
    enabled? = PhoenixDevToolbar.enabled?()
    settle_redact(enabled?)
    settle_allowed_origins(enabled?)

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
  # Unset `enabled` means on only under Mix in the `:dev` env. Running without
  # Mix is a release, any other Mix env is test or prod: the package was
  # installed without `only: :dev`. Turn off unless `enabled` was set
  # explicitly (ADR 01). `mix_env` is `nil` when Mix is not loaded.
  @spec settle_enabled({:ok, term()} | :error, atom() | nil) :: :ok
  def settle_enabled({:ok, _explicit}, _mix_env), do: :ok
  def settle_enabled(:error, :dev), do: :ok

  def settle_enabled(:error, nil) do
    Application.put_env(:phoenix_dev_toolbar, :enabled, false)

    Logger.warning(
      "[phoenix_dev_toolbar] running outside Mix (a release?): the toolbar is disabled. " <>
        "Declare the dependency with `only: :dev`, or set `enabled: true` to force it."
    )
  end

  def settle_enabled(:error, mix_env) do
    Application.put_env(:phoenix_dev_toolbar, :enabled, false)

    Logger.warning(
      "[phoenix_dev_toolbar] the Mix env is #{inspect(mix_env)}, not :dev: the toolbar is " <>
        "disabled there. Set `config :phoenix_dev_toolbar, enabled: false` to silence this, " <>
        "or `enabled: true` to turn it on."
    )
  end

  @doc false
  # Validates `redact:` once at boot, so the hot path reads a clean list.
  @spec settle_redact(boolean()) :: :ok
  def settle_redact(false), do: :ok

  def settle_redact(true) do
    case Application.fetch_env(:phoenix_dev_toolbar, :redact) do
      {:ok, configured} ->
        Application.put_env(:phoenix_dev_toolbar, :redact, Config.redact(configured))

      :error ->
        :ok
    end
  end

  @doc false
  # Validates `allowed_origins:` once at boot: a typo is logged, not only refused.
  @spec settle_allowed_origins(boolean()) :: :ok
  def settle_allowed_origins(false), do: :ok

  def settle_allowed_origins(true) do
    case Application.fetch_env(:phoenix_dev_toolbar, :allowed_origins) do
      {:ok, configured} ->
        Application.put_env(
          :phoenix_dev_toolbar,
          :allowed_origins,
          Config.allowed_origins(configured)
        )

      :error ->
        :ok
    end
  end

  # `Mix.env/0` only when Mix is loaded: a release has no Mix.
  defp mix_env do
    case Code.ensure_loaded?(Mix) do
      true -> Mix.env()
      false -> nil
    end
  end

  @doc false
  # Disabled means no processes, no ETS tables and no handlers (ADR 01).
  @spec children(boolean()) :: [module()]
  def children(false), do: []

  def children(true),
    do: [
      PhoenixDevToolbar.Store,
      PhoenixDevToolbar.Notify,
      PhoenixDevToolbar.Suspender,
      PhoenixDevToolbar.Tracer
    ]

  @doc false
  @spec maybe_attach(boolean()) :: :ok
  def maybe_attach(false), do: :ok

  def maybe_attach(true) do
    ClientPolicy.warn_config()
    Config.warn_mcp()
    Config.warn_ui()
    Collector.attach(plugins())
  end
end
