defmodule PhoenixDevToolbar.Mcp.Endpoint do
  @moduledoc false
  # The HTTP side of the MCP endpoint (ADR 15), served by the plug at
  # `<path>/mcp`. Guards run in order and each refusal is a short text/plain
  # body naming the fix. Runs in the host's request process: nothing here may
  # raise out of `call/3`.

  alias PhoenixDevToolbar.ClientMatch
  alias PhoenixDevToolbar.ClientPolicy
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
  @client_refusal "MCP is limited to this machine: allow other clients with `mcp: [clients: [...]]` in the toolbar config."
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
        {:refuse, 403, @client_refusal}

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

  defp client_allowed?(_conn, :any, _own_addresses), do: true

  defp client_allowed?(conn, mode, own_addresses) do
    not OriginCheck.proxied?(conn) and peer_allowed?(conn.remote_ip, mode, own_addresses)
  end

  defp peer_allowed?(peer, mode, own_addresses) do
    ClientPolicy.loopback?(peer) or listed?(peer, mode) or
      ClientMatch.local?(peer, own_addresses.())
  end

  defp listed?(peer, {:list, entries}), do: ClientMatch.matches?(peer, entries)
  defp listed?(_peer, _mode), do: false

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

  defp base_url(conn, base_path) do
    "#{conn.scheme}://#{host_literal(conn.host)}:#{conn.port}#{base_path}"
  end

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
