defmodule PhoenixDevToolbar.OriginCheck do
  @moduledoc false
  # Origin rules shared by the panel socket and the MCP endpoint (ADR 04).

  alias PhoenixDevToolbar.Config

  @forwarded ~w(x-forwarded-for x-forwarded-host x-forwarded-proto x-real-ip forwarded)

  @doc false
  @spec proxied?(Plug.Conn.t()) :: boolean()
  def proxied?(conn), do: Enum.any?(@forwarded, &(Plug.Conn.get_req_header(conn, &1) != []))

  @doc false
  @spec same_origin?(Plug.Conn.t()) :: boolean()
  def same_origin?(conn) do
    with [origin] <- Plug.Conn.get_req_header(conn, "origin"),
         %URI{scheme: scheme, host: origin_host, port: origin_port}
         when scheme in ["http", "https"] and is_binary(origin_host) <- URI.parse(origin),
         {host, port} <- request_authority(conn) do
      String.downcase(origin_host) == String.downcase(host) and port_matches?(origin_port, port)
    else
      _missing_or_malformed -> false
    end
  end

  @doc false
  @spec allowed_origin?(Plug.Conn.t()) :: boolean()
  def allowed_origin?(conn) do
    with [origin] <- Plug.Conn.get_req_header(conn, "origin"),
         {:ok, origin} <- Config.origin(origin) do
      :phoenix_dev_toolbar
      |> Application.get_env(:allowed_origins, [])
      |> List.wrap()
      |> Enum.any?(&(Config.origin(&1) == {:ok, origin}))
    else
      _missing_or_malformed -> false
    end
  end

  # What the browser addressed: the `Host` header (host and optional port).
  defp request_authority(conn) do
    case Plug.Conn.get_req_header(conn, "host") do
      [authority] ->
        case URI.parse("//" <> authority) do
          %URI{host: host, port: port} when is_binary(host) -> {host, port}
          _malformed -> :error
        end

      [] ->
        {conn.host, nil}

      _several ->
        :error
    end
  end

  defp port_matches?(origin_port, nil), do: origin_port in [80, 443]
  defp port_matches?(origin_port, port), do: origin_port == port
end
