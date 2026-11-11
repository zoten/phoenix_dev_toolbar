defmodule PhoenixDevToolbar.ClientMatch do
  @moduledoc false
  # Who counts as which client (ADR 15): `allowed?/4` is the one rule for
  # "this machine" (loopback or one of our own interface addresses), plus an
  # allowlist or anyone. Parses "a.b.c.d", "a.b.c.d/n", IPv6 "x::y" and
  # "x::y/n" into `{ip, prefix}` and tests peers with integer bit masks. No
  # atoms are created from input.

  import Bitwise

  @type ip :: :inet.ip_address()
  @type entry :: {ip(), non_neg_integer()}
  @type mode :: :local | {:list, [entry()]} | :any

  @doc """
  Whether a client may in: `:any` always; otherwise never through a proxy (the
  peer would be the proxy), and only a loopback peer, a listed one, or one of
  this machine's own addresses. `own_addresses` is called last, only if needed.
  """
  @spec allowed?(ip() | nil, mode(), boolean(), (-> [ip()])) :: boolean()
  def allowed?(_peer, :any, _proxied?, _own_addresses), do: true
  def allowed?(_peer, _mode, true, _own_addresses), do: false

  def allowed?(peer, mode, false, own_addresses) when is_tuple(peer) do
    loopback?(peer) or listed?(peer, mode) or local?(peer, own_addresses.())
  end

  def allowed?(_peer, _mode, _proxied?, _own_addresses), do: false

  @doc "Whether `peer` is a loopback address (IPv4, IPv6 or IPv4 mapped)."
  @spec loopback?(term()) :: boolean()
  def loopback?(peer) when is_tuple(peer) do
    case normalize(peer) do
      {127, _b, _c, _d} -> true
      {0, 0, 0, 0, 0, 0, 0, 1} -> true
      _other -> false
    end
  end

  def loopback?(_peer), do: false

  defp listed?(peer, {:list, entries}), do: matches?(peer, entries)
  defp listed?(_peer, _mode), do: false

  @doc "Parses one `clients:` entry. Anything that is not a valid IP or CIDR is `:error`."
  @spec parse(term()) :: {:ok, entry()} | :error
  def parse(term) when is_binary(term) do
    case String.valid?(term) and String.split(term, "/") do
      [address] -> address |> parse_ip() |> with_prefix(nil)
      [address, bits] -> address |> parse_ip() |> with_prefix(parse_bits(bits))
      _invalid -> :error
    end
  end

  def parse(_other), do: :error

  defp parse_ip(address) do
    case :inet.parse_strict_address(String.to_charlist(address)) do
      {:ok, ip} -> {:ok, normalize(ip)}
      {:error, _reason} -> :error
    end
  end

  defp parse_bits(bits) do
    case Regex.match?(~r/\A\d{1,3}\z/, bits) do
      true -> String.to_integer(bits)
      false -> :error
    end
  end

  defp with_prefix({:ok, ip}, nil), do: {:ok, {ip, width(ip)}}

  defp with_prefix({:ok, ip}, bits) when is_integer(bits) and bits <= 32 and tuple_size(ip) == 4,
    do: {:ok, {ip, bits}}

  defp with_prefix({:ok, ip}, bits) when is_integer(bits) and bits <= 128 and tuple_size(ip) == 8,
    do: {:ok, {ip, bits}}

  defp with_prefix(_ip, _bits), do: :error

  @doc "Whether `peer` falls inside any parsed entry."
  @spec matches?(ip(), [entry()]) :: boolean()
  def matches?(peer, entries) do
    peer = normalize(peer)
    Enum.any?(entries, fn {ip, bits} -> same_family?(peer, ip) and in_range?(peer, ip, bits) end)
  end

  @doc "Whether `peer` is one of `addresses` (this machine's interface addresses)."
  @spec local?(ip(), [ip()]) :: boolean()
  def local?(peer, addresses) do
    peer = normalize(peer)
    Enum.any?(addresses, &(normalize(&1) == peer))
  end

  @doc "This machine's interface addresses; an unreadable list is empty."
  @spec own_addresses() :: [ip()]
  def own_addresses do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        for {_name, opts} <- interfaces, {:addr, ip} <- opts, do: ip

      {:error, _reason} ->
        []
    end
  end

  defp normalize({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  defp normalize(ip), do: ip

  defp same_family?(a, b), do: tuple_size(a) == tuple_size(b)

  defp in_range?(peer, ip, bits) do
    shift = width(ip) - bits
    to_int(peer) >>> shift == to_int(ip) >>> shift
  end

  defp width(ip) when tuple_size(ip) == 4, do: 32
  defp width(ip) when tuple_size(ip) == 8, do: 128

  defp group_bits(ip) when tuple_size(ip) == 4, do: 8
  defp group_bits(ip) when tuple_size(ip) == 8, do: 16

  defp to_int(ip) do
    group = group_bits(ip)

    ip
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> acc <<< group ||| part end)
  end
end
