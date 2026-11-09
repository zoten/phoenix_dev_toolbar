defmodule PhoenixDevToolbar.Plugins.Cluster do
  @moduledoc """
  The Cluster tab (ADR 12): this node and its connected nodes, with each one's
  round trip time, process count, memory, OTP release and uptime. Not in
  `:defaults`: add it to the toolbar's `plugins:`.

      config :phoenix_dev_toolbar, plugins: [:defaults, PhoenixDevToolbar.Plugins.Cluster]

  Option: `refresh_ms:` how often the nodes are read while the tab is shown,
  5000 by default (1000 to 60000).
  """

  use PhoenixDevToolbar.Plugin, id: :cluster, name: "Cluster"

  @default_refresh_ms 5000

  @impl PhoenixDevToolbar.Plugin
  def init(opts) do
    case Keyword.keys(opts) -- [:refresh_ms] do
      [] -> refresh(Keyword.get(opts, :refresh_ms, @default_refresh_ms))
      unknown -> {:error, "unknown options #{inspect(unknown)}, expected [:refresh_ms]"}
    end
  end

  defp refresh(ms) when is_integer(ms) and ms >= 1000 and ms <= 60_000,
    do: {:ok, %{refresh_ms: ms}}

  defp refresh(other),
    do:
      {:error,
       "refresh_ms must be an integer from 1000 to 60000, got: #{inspect(other, limit: 5)}"}

  @doc false
  @spec config(term()) :: %{refresh_ms: pos_integer()}
  def config(%{refresh_ms: _} = config), do: config
  def config(_config), do: %{refresh_ms: @default_refresh_ms}

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: []

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: :skip

  @impl PhoenixDevToolbar.Plugin
  def panel, do: PhoenixDevToolbar.Panels.Cluster
end
