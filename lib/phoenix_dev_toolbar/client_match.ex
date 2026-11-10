defmodule PhoenixDevToolbar.ClientMatch do
  @moduledoc false
  # Pure IP matching for the MCP `clients:` option (ADR 15): parses "a.b.c.d",
  # "a.b.c.d/n", IPv6 "x::y" and "x::y/n" into `{ip, prefix}` and tests peers
  # with integer bit masks. No atoms are created from input.

  import Bitwise

  @type ip :: :inet.ip_address()
  @type entry :: {ip(), non_neg_integer()}

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

  defp to_int(ip) do
    group = if tuple_size(ip) == 4, do: 8, else: 16

    ip
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> acc <<< group ||| part end)
  end
end
