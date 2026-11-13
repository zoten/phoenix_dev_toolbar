defmodule PhoenixDevToolbar.McpHint do
  @moduledoc false
  # One info line per boot with the MCP URL the browser's request reached, so
  # an agent's `.mcp.json` can use an address the server listens on (ADR 15).
  # Called from the plug for tracked requests: one `:persistent_term.get/2` once
  # the line is out. Never raises.

  require Logger

  alias PhoenixDevToolbar.Config
  alias PhoenixDevToolbar.Mcp.Endpoint
  alias PhoenixDevToolbar.OriginCheck

  @flag {__MODULE__, :logged}

  @doc "Logs the MCP URL once per boot, on the first loopback request (not when MCP is off)."
  @spec announce(Plug.Conn.t(), String.t()) :: :ok
  def announce(conn, base_path) do
    case :persistent_term.get(@flag, false) do
      true -> :ok
      false -> first(conn, base_path)
    end
  rescue
    _error -> :ok
  end

  @doc "Forgets that the line was logged (tests)."
  @spec reset() :: :ok
  def reset do
    _ = :persistent_term.erase(@flag)
    :ok
  end

  # Only a direct loopback client counts: another machine's or a proxied
  # request (the MCP endpoint refuses those) leaves the flag unset, so a later
  # local one logs the line (the URL an agent here can use).
  defp first(conn, base_path) do
    case Config.mcp?() and loopback_client?(conn) do
      true ->
        :persistent_term.put(@flag, true)
        Logger.info(message(conn, base_path))

      false ->
        :ok
    end
  end

  defp loopback_client?(%{remote_ip: ip} = conn),
    do: loopback?(ip) and not OriginCheck.proxied?(conn)

  defp message(conn, base_path) do
    url = Endpoint.base_url(conn, base_path) <> "/mcp"
    "[phoenix_dev_toolbar] MCP at #{url}" <> loopback_note(conn)
  end

  defp loopback_note(conn) do
    case loopback_ip(conn) do
      nil ->
        ""

      ip ->
        " (listening on #{ip} only: an MCP URL with another address is refused)"
    end
  end

  defp loopback_ip(conn) do
    with endpoint when is_atom(endpoint) <- conn.private[:phoenix_endpoint],
         http when is_list(http) <- endpoint.config(:http),
         ip when is_tuple(ip) <- Keyword.get(http, :ip),
         true <- loopback?(ip) do
      ip |> :inet.ntoa() |> to_string()
    else
      _other -> nil
    end
  rescue
    _error -> nil
  end

  defp loopback?({127, _b, _c, _d}), do: true
  defp loopback?({0, 0, 0, 0, 0, 65_535, high, _low}), do: div(high, 256) == 127
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_ip), do: false
end
