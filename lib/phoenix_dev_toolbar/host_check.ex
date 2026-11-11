defmodule PhoenixDevToolbar.HostCheck do
  @moduledoc false
  # DNS rebinding guard for the toolbar's own routes (ADR 04): a hostile page
  # whose name re-resolves to 127.0.0.1 would load the panel as same origin, and
  # its websocket would come from the developer's own browser (a loopback peer).
  # So the panel, its socket and the export answer only for a Host that cannot be
  # rebound: an IP literal, `localhost` and `*.localhost`, the endpoint's
  # configured `url: [host: ...]`, or one listed in `allowed_hosts:`
  # (`"myapp.test"`, or `".test"` for every name under it).

  require Logger

  @logged {PhoenixDevToolbar.HostCheck, :logged}
  # Distinct refused hosts named in the log, at most (an attacker can send any).
  @max_logged 10

  @doc "Whether the request's Host may reach the panel."
  @spec allowed?(Plug.Conn.t()) :: boolean()
  def allowed?(%Plug.Conn{host: host} = conn) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]") |> String.downcase()

    ip?(host) or localhost?(host) or host == endpoint_host(conn) or listed?(host)
  end

  @doc """
  Logs a refused host and how to allow it: once per host, for the first
  #{@max_logged} distinct ones of a boot.
  """
  @spec log_refused(String.t()) :: :ok
  def log_refused(host) do
    host = String.slice(host, 0, 100)
    logged = :persistent_term.get(@logged, [])

    case host in logged or length(logged) >= @max_logged do
      true ->
        :ok

      false ->
        :persistent_term.put(@logged, [host | logged])

        Logger.warning(
          "[phoenix_dev_toolbar] refused a toolbar request for host #{inspect(host)}: " <>
            "add it to `allowed_hosts:` in the toolbar config if it is yours (DNS rebinding guard)"
        )
    end
  end

  @doc false
  # Forgets the logged hosts, so a test sees the first refusal of each again.
  @spec reset_logged() :: :ok
  def reset_logged do
    _ = :persistent_term.erase(@logged)
    :ok
  end

  defp ip?(host), do: match?({:ok, _ip}, :inet.parse_address(String.to_charlist(host)))

  defp localhost?(host), do: host == "localhost" or String.ends_with?(host, ".localhost")

  defp endpoint_host(%Plug.Conn{private: %{phoenix_endpoint: endpoint}}) do
    case endpoint.config(:url)[:host] do
      host when is_binary(host) -> String.downcase(host)
      _none -> nil
    end
  rescue
    _error -> nil
  end

  defp endpoint_host(_conn), do: nil

  defp listed?(host) do
    :phoenix_dev_toolbar
    |> Application.get_env(:allowed_hosts, [])
    |> List.wrap()
    |> Enum.any?(&matches?(host, &1))
  end

  defp matches?(host, "." <> _suffix = pattern),
    do: String.ends_with?(host, String.downcase(pattern))

  defp matches?(host, pattern) when is_binary(pattern), do: host == String.downcase(pattern)
  defp matches?(_host, _pattern), do: false
end
