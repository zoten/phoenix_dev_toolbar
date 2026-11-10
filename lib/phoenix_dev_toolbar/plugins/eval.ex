defmodule PhoenixDevToolbar.Plugins.Eval do
  @moduledoc """
  > #### Experimental {: .warning}
  >
  > This API may change in any 0.0.x release. Changes are listed in the CHANGELOG.

  The Eval tab ([ADR 12](https://github.com/zoten/phoenix_dev_toolbar/blob/main/adr/12-cluster-and-eval-plugins.md)): read queries about the running node and, only when you
  allow it, code you type, evaluated on the node. Not in `:defaults`: add it to
  the toolbar's `plugins:`.

      config :phoenix_dev_toolbar,
        plugins: [:defaults, {PhoenixDevToolbar.Plugins.Eval, allow: :eval}]

  Options, each with a safe default:

    * `allow:` `:read_only` (default: a fixed list of read queries, no code) or
      `:eval` (code typed in the panel runs on the node)
    * `clients:` who may run code: `:loopback` (default: only a browser on this
      machine, reaching the server directly) or `:any` (any browser that reaches
      the dev server, Docker or LAN setups). Read queries answer any browser, like
      the System tab.
    * `timeout_ms:` how long code may run before it is stopped, 5000 by default
      (100 to 60000)

  Eval is its own opt-in and does not depend on the top level `actions:` option
  (kill, suspend, message peek: off by default). It is refused only when the host
  sets `actions: false` explicitly.

  `allow: :eval` with `clients: :any` lets anyone who reaches the dev server run
  code as the BEAM user: both overrides are warned about when the toolbar
  starts. See [SECURITY.md](SECURITY.md).
  """

  use PhoenixDevToolbar.Plugin, id: :eval, name: "Eval"

  require Logger

  @defaults %{allow: :read_only, clients: :loopback, timeout_ms: 5000}

  @impl PhoenixDevToolbar.Plugin
  def init(opts) do
    case Keyword.keys(opts) -- Map.keys(@defaults) do
      [] ->
        opts |> Enum.into(@defaults) |> validate() |> warn()

      unknown ->
        {:error, "unknown options #{inspect(unknown)}, expected #{inspect(Map.keys(@defaults))}"}
    end
  end

  defp validate(%{allow: allow}) when allow not in [:read_only, :eval],
    do: {:error, "allow must be :read_only or :eval, got: #{inspect(allow, limit: 5)}"}

  defp validate(%{clients: clients}) when clients not in [:loopback, :any],
    do: {:error, "clients must be :loopback or :any, got: #{inspect(clients, limit: 5)}"}

  defp validate(%{timeout_ms: ms}) when not (is_integer(ms) and ms >= 100 and ms <= 60_000),
    do: {:error, "timeout_ms must be an integer from 100 to 60000, got: #{inspect(ms, limit: 5)}"}

  defp validate(config), do: {:ok, config}

  defp warn({:ok, config}) do
    warn_overrides(config)
    {:ok, config}
  end

  defp warn(error), do: error

  defp warn_overrides(%{allow: :eval, clients: clients}) do
    Logger.warning(
      "[phoenix_dev_toolbar] the Eval tab runs code typed in the panel (allow: :eval)" <>
        clients_note(clients)
    )
  end

  defp warn_overrides(_defaults), do: :ok

  defp clients_note(:any),
    do: " for any browser (clients: :any): anyone who reaches this dev server can run code here."

  defp clients_note(:loopback), do: ", for a browser on this machine only."

  @doc false
  @spec config(term()) :: %{
          allow: :read_only | :eval,
          clients: :loopback | :any,
          timeout_ms: pos_integer()
        }
  def config(%{allow: _, clients: _, timeout_ms: _} = config), do: config
  def config(_config), do: @defaults

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: []

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: :skip

  @impl PhoenixDevToolbar.Plugin
  def panel, do: PhoenixDevToolbar.Panels.Eval
end
