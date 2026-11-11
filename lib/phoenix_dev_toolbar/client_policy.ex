defmodule PhoenixDevToolbar.ClientPolicy do
  @moduledoc false
  # Who may act on host processes or copy their data (kill, suspend, message
  # peek, state read: ADR 10), from the top level `actions:` config:
  #
  #   * `false` (default): nobody; acting on host processes is opt-in
  #   * `:local`: only a panel whose socket peer is this machine (loopback or
  #     one of its own interface addresses), never through a proxy. `:loopback`
  #     is the same, kept for old configs
  #   * `:any`: any panel the panel socket lets in (warned at boot)
  #
  # Process info reads, GC and Watch never ask here. A browser outside the container (Docker) or on
  # another machine is not local: such setups set `actions: :any`.

  require Logger

  alias PhoenixDevToolbar.ClientMatch

  @type mode :: :local | :any | false

  @doc "The configured mode, `false` when unset; an invalid value counts as `false`."
  @spec mode() :: mode()
  def mode do
    case Application.get_env(:phoenix_dev_toolbar, :actions, false) do
      mode when mode in [:local, :loopback] -> :local
      :any -> :any
      _off_or_invalid -> false
    end
  end

  @doc """
  Whether the host set `actions: false` itself. Unset is also off, but the Eval
  plugin (its own opt-in, with its own `clients:`) is refused only on an
  explicit `false`.
  """
  @spec explicitly_off?() :: boolean()
  def explicitly_off?, do: Application.fetch_env(:phoenix_dev_toolbar, :actions) == {:ok, false}

  @doc """
  Whether a client at `address` (the panel socket's peer, nil when proxied) may
  run actions. `own_addresses` is injectable for tests.
  """
  @spec check_actions(:inet.ip_address() | nil, (-> [:inet.ip_address()])) ::
          :ok | {:error, :disabled | :not_local}
  def check_actions(address, own_addresses \\ &ClientMatch.own_addresses/0) do
    case mode() do
      :any -> :ok
      false -> {:error, :disabled}
      :local -> local(local?(address, own_addresses))
    end
  end

  @doc """
  Like `check_actions/2` for a verdict computed earlier (`local?/2`, once per
  panel mount): no interface lookup.
  """
  @spec check_actions_for(boolean()) :: :ok | {:error, :disabled | :not_local}
  def check_actions_for(local?) do
    case mode() do
      :any -> :ok
      false -> {:error, :disabled}
      :local -> local(local?)
    end
  end

  @doc """
  Whether `address` is this machine: loopback or one of its own interface
  addresses. Nil (a proxied panel) never is.
  """
  @spec local?(:inet.ip_address() | nil, (-> [:inet.ip_address()])) :: boolean()
  def local?(address, own_addresses \\ &ClientMatch.own_addresses/0),
    do: ClientMatch.allowed?(address, :local, false, own_addresses)

  defp local(true), do: :ok
  defp local(false), do: {:error, :not_local}

  @doc "Whether `address` is a loopback address (IPv4, IPv6 or IPv4 mapped)."
  @spec loopback?(term()) :: boolean()
  defdelegate loopback?(address), to: ClientMatch

  @doc "Logs, at boot, an `actions:` value that is invalid or opens actions to anyone."
  @spec warn_config() :: :ok
  def warn_config do
    case Application.get_env(:phoenix_dev_toolbar, :actions, false) do
      valid when valid in [:local, :loopback, false] ->
        :ok

      :any ->
        Logger.warning(
          "[phoenix_dev_toolbar] actions: :any lets anyone who reaches this dev server " <>
            "kill and suspend its processes. Use it only on a trusted network."
        )

      invalid ->
        Logger.warning(
          "[phoenix_dev_toolbar] invalid actions: #{inspect(invalid, limit: 5)}, " <>
            "expected :local, :any or false. Using false."
        )
    end
  end
end
