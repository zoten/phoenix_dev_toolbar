defmodule PhoenixDevToolbar.Mcp.Endpoint do
  @moduledoc false
  # The HTTP side of the MCP endpoint (ADR 15), served by the plug at
  # `<path>/mcp`. Guards run in order and each refusal is a short text/plain
  # body naming the fix. Runs in the host's request process: nothing here may
  # raise out of `call/3`.

  require Logger

  alias PhoenixDevToolbar.ClientMatch
  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Config
  alias PhoenixDevToolbar.HostCheck
  alias PhoenixDevToolbar.Mcp.Endpoint
  alias PhoenixDevToolbar.Mcp.Json
  alias PhoenixDevToolbar.Mcp.Protocol
  alias PhoenixDevToolbar.OriginCheck
  alias Plug.Conn

  @max_body 1_000_000
  @internal_error ~s({"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}})
  @proxy_refusal "MCP refused a proxied request: only `mcp: [clients: :any]` accepts requests through a proxy."
  @max_logged 10
  @logged :phoenix_dev_toolbar_mcp_refused_clients
  @headers ["mcp-protocol-version", "mcp-method", "mcp-name"]

  @doc "Answers the request: the conn comes back halted with the response sent."
  @spec call(Conn.t(), String.t(), (-> [:inet.ip_address()])) :: Conn.t()
  def call(%Conn{} = conn, base_path, own_addresses \\ &ClientMatch.own_addresses/0) do
    case guard(conn, own_addresses) do
      {:refuse, status, message} -> text(conn, status, message)
      :ok -> conn |> read_message() |> respond(base_path)
    end
  end

  defp guard(conn, own_addresses) do
    cond do
      not Config.mcp?() ->
        {:refuse, 404, "MCP is off. Remove `mcp: false` from the toolbar config to enable it."}

      not HostCheck.allowed?(conn) ->
        HostCheck.log_refused(conn.host)
        {:refuse, 403, "Host not allowed. Add it to `allowed_hosts:` in the toolbar config."}

      not client_allowed?(conn, Config.mcp(), own_addresses) ->
        refuse_client(conn)

      not origin_ok?(conn) ->
        {:refuse, 403,
         "Origin not allowed. Agents send no Origin; list a browser origin in `allowed_origins:`."}

      conn.method != "POST" ->
        {:refuse, 405, "Use POST."}

      not json?(conn) ->
        {:refuse, 415, "Send Content-Type: application/json."}

      true ->
        :ok
    end
  end

  defp refuse_client(conn) do
    peer = peer_text(conn.remote_ip)
    proxied? = OriginCheck.proxied?(conn)
    log_refused(peer, proxied?)

    case proxied? do
      true ->
        {:refuse, 403, @proxy_refusal}

      false ->
        {:refuse, 403,
         "MCP is limited to this machine and refused #{peer}: allow other clients with " <>
           "`mcp: [clients: [...]]` in the toolbar config."}
    end
  end

  # `:inet.ntoa/1` answers `{:error, :einval}` for anything but an address.
  defp peer_text(ip) do
    case :inet.ntoa(ip) do
      {:error, _reason} -> "unknown"
      text -> List.to_string(text)
    end
  end

  # Once per distinct peer, at most @max_logged per boot (like `HostCheck.log_refused/1`).
  defp log_refused(peer, proxied?) do
    logged = :persistent_term.get(@logged, [])

    case peer in logged or length(logged) >= @max_logged do
      true ->
        :ok

      false ->
        :persistent_term.put(@logged, [peer | logged])

        Logger.warning(refusal_log(peer, proxied?))
    end
  end

  defp refusal_log(peer, true) do
    "[phoenix_dev_toolbar] refused a proxied MCP request from #{peer}: " <>
      "only `mcp: [clients: :any]` accepts requests through a proxy"
  end

  defp refusal_log(peer, false) do
    "[phoenix_dev_toolbar] refused an MCP request from #{peer}: " <>
      "allow it with `mcp: [clients: [...]]` in the toolbar config if it is yours"
  end

  defp client_allowed?(conn, mode, own_addresses),
    do: ClientMatch.allowed?(conn.remote_ip, mode, OriginCheck.proxied?(conn), own_addresses)

  defp origin_ok?(conn) do
    case Conn.get_req_header(conn, "origin") do
      [] -> true
      _present -> OriginCheck.same_origin?(conn) or OriginCheck.allowed_origin?(conn)
    end
  end

  defp json?(conn) do
    case Conn.get_req_header(conn, "content-type") do
      [type | _] -> type |> String.downcase() |> String.starts_with?("application/json")
      [] -> false
    end
  end

  defp read_message(%Conn{body_params: %Conn.Unfetched{}} = conn) do
    case Conn.read_body(conn, length: @max_body) do
      {:ok, body, conn} -> {decode(body), conn}
      {:more, _partial, conn} -> {{:refuse, 413, "Body over 1 MB."}, conn}
      {:error, _reason} -> {{:refuse, 400, "Could not read the body."}, conn}
    end
  end

  defp read_message(%Conn{body_params: params} = conn), do: {{:ok, unwrap(params)}, conn}

  defp unwrap(%{"_json" => value} = params) when map_size(params) == 1, do: value
  defp unwrap(params), do: params

  defp decode(body) do
    case Json.decode(body) do
      {:ok, message} -> {:ok, message}
      {:error, :parse} = error -> {:ok, error}
    end
  end

  defp respond({{:refuse, status, message}, conn}, _base_path), do: text(conn, status, message)

  defp respond({{:ok, message}, conn}, base_path) do
    headers = Map.new(@headers, &{&1, conn |> Conn.get_req_header(&1) |> List.first()})
    headers = Map.reject(headers, fn {_name, value} -> is_nil(value) end)
    opts = [base_url: base_url(conn, base_path), server_version: server_version()]

    {status, body} = run(message, headers, opts)
    send_protocol(conn, status, body)
  end

  # Handling and encoding share one protected region: any failure is a static 500.
  defp run(message, headers, opts) do
    case Protocol.handle(message, headers, opts) do
      {status, nil} -> {status, nil}
      {status, body} -> {status, Json.encode!(body)}
    end
  catch
    kind, reason ->
      Collector.log_failure(Endpoint, "MCP request failed", kind, reason, __STACKTRACE__)
      {500, @internal_error}
  end

  @doc false
  # Absolute URL of the toolbar's own path as the request reached it (the MCP
  # `panel_url`s and the panel's Markdown footer).
  @spec base_url(Plug.Conn.t(), String.t()) :: String.t()
  def base_url(conn, base_path) do
    "#{conn.scheme}://#{host_literal(conn.host)}#{port_suffix(conn.scheme, conn.port)}#{base_path}"
  end

  defp port_suffix(:http, 80), do: ""
  defp port_suffix(:https, 443), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"

  defp host_literal("[" <> _ = host), do: host

  defp host_literal(host) do
    case String.contains?(host, ":") do
      true -> "[" <> host <> "]"
      false -> host
    end
  end

  defp server_version do
    case Application.spec(:phoenix_dev_toolbar, :vsn) do
      nil -> "0.0.0"
      vsn -> List.to_string(vsn)
    end
  end

  defp send_protocol(conn, status, nil), do: conn |> secure() |> reply(status, "")

  defp send_protocol(conn, status, body) do
    conn
    |> secure()
    |> Conn.put_resp_content_type("application/json")
    |> reply(status, body)
  end

  defp text(conn, status, message) do
    conn
    |> secure()
    |> Conn.put_resp_content_type("text/plain")
    |> maybe_allow(status)
    |> reply(status, message)
  end

  defp maybe_allow(conn, 405), do: Conn.put_resp_header(conn, "allow", "POST")
  defp maybe_allow(conn, _status), do: conn

  defp secure(conn) do
    conn
    |> Conn.put_resp_header("cache-control", "no-store")
    |> Conn.put_resp_header("x-content-type-options", "nosniff")
  end

  defp reply(conn, status, body), do: conn |> Conn.send_resp(status, body) |> Conn.halt()
end
