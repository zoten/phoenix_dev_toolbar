defmodule PhoenixDevToolbar.ClientPolicy do
  @moduledoc false
  # Who may act on host processes or copy their data (kill, suspend, message
  # peek, state read: ADR 10), from the top level `actions:` config:
  #
  #   * `false` (default): nobody; acting on host processes is opt-in
  #   * `:loopback`: only a panel whose socket peer is a loopback address
  #   * `:any`: any panel the panel socket lets in (warned at boot)
  #
  # Process info reads, GC and Watch never ask here. A browser outside the container (Docker) or on
  # the LAN is not loopback: such setups set `actions: :any`.

  import Bitwise

  require Logger

  @type mode :: :loopback | :any | false

  @doc "The configured mode, `false` when unset; an invalid value counts as `false`."
  @spec mode() :: mode()
  def mode do
    case Application.get_env(:phoenix_dev_toolbar, :actions, false) do
      mode when mode in [:loopback, :any] -> mode
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

  @doc "Whether a client at `address` (the panel socket's peer) may run actions."
  @spec check_actions(:inet.ip_address() | nil) :: :ok | {:error, :disabled | :not_loopback}
  def check_actions(address) do
    case mode() do
      :any -> :ok
      false -> {:error, :disabled}
      :loopback -> loopback(address)
    end
  end

  defp loopback(address) do
    case loopback?(address) do
      true -> :ok
      false -> {:error, :not_loopback}
    end
  end

  @doc "Whether `address` is a loopback address (IPv4, IPv6 or IPv4 mapped)."
  @spec loopback?(term()) :: boolean()
  def loopback?({127, _b, _c, _d}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?({0, 0, 0, 0, 0, 0xFFFF, high, _low}) when is_integer(high), do: high >>> 8 == 127
  def loopback?(_address), do: false

  @doc "Logs, at boot, an `actions:` value that is invalid or opens actions to anyone."
  @spec warn_config() :: :ok
  def warn_config do
    case Application.get_env(:phoenix_dev_toolbar, :actions, false) do
      valid when valid in [:loopback, false] ->
        :ok

      :any ->
        Logger.warning(
          "[phoenix_dev_toolbar] actions: :any lets anyone who reaches this dev server " <>
            "kill and suspend its processes. Use it only on a trusted network."
        )

      invalid ->
        Logger.warning(
          "[phoenix_dev_toolbar] invalid actions: #{inspect(invalid, limit: 5)}, " <>
            "expected :loopback, :any or false. Using false."
        )
    end
  end
end
