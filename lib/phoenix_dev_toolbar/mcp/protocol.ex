defmodule PhoenixDevToolbar.Mcp.Protocol do
  @moduledoc false
  # MCP over JSON-RPC, stateless (ADR 15). Pure: a decoded message in, an HTTP
  # status and a response body out. Serves the legacy lifecycle (2025-03-26 to
  # 2025-11-25) and 2026-07-28 on the same endpoint.

  alias PhoenixDevToolbar.Mcp.Json
  alias PhoenixDevToolbar.Mcp.Tools

  @legacy ["2025-11-25", "2025-06-18", "2025-03-26"]
  @modern "2026-07-28"
  @supported [@modern | @legacy]
  @meta_version "io.modelcontextprotocol/protocolVersion"
  @server_info_key "io.modelcontextprotocol/serverInfo"

  @instructions "Read-only access to what Phoenix Dev Toolbar captured in the running dev app: " <>
                  "list_pages, then page_summary, page_queries, page_callbacks, page_n_plus_one " <>
                  "and page_errors for a page, page_report for a page as Markdown, recent_errors for failures across pages (also after a change). list_pages takes since (a sid or a time) for " <>
                  "pages captured after an earlier call. To check a change: page_summary, note " <>
                  "its sid, edit, reload the page, then compare_pages with before: sid. " <>
                  "Load the page first (a browser, or curl with " <>
                  "Accept: text/html): only pages captured in the last 10 minutes are available."

  @type headers :: %{String.t() => String.t()}
  @type opts :: [base_url: String.t(), server_version: String.t()]
  @type response :: {pos_integer(), %{String.t() => term()} | nil}

  @doc "Handles one decoded message (or `{:error, :parse}`)."
  @spec handle(term(), headers(), opts()) :: response()
  def handle({:error, :parse}, _headers, _opts), do: error(400, nil, -32_700, "Parse error")

  def handle(batch, _headers, _opts) when is_list(batch) do
    error(400, nil, -32_600, "Batches are not supported")
  end

  def handle(%{"jsonrpc" => "2.0", "method" => method} = message, headers, opts)
      when is_binary(method) do
    case valid_id?(message) do
      true -> request(message, method, headers, opts)
      false -> error(400, nil, -32_600, "Invalid request: id must be a string or an integer")
    end
  end

  def handle(_message, _headers, _opts), do: error(400, nil, -32_600, "Invalid request")

  defp valid_id?(%{"id" => id}), do: is_binary(id) or is_integer(id)
  defp valid_id?(_message), do: true

  defp request(message, method, headers, opts) do
    params = params(message)

    with {:ok, era} <- era(method, params, headers),
         :ok <- check_headers(era, method, params, headers) do
      dispatch(message, method, params, era, opts)
    else
      {:error, {status, code, text, data}} -> error(status, id_of(message), code, text, data)
    end
  end

  defp params(%{"params" => params}) when is_map(params), do: params
  defp params(_message), do: %{}

  defp id_of(message), do: Map.get(message, "id")

  # {:ok, {:legacy, version} | {:modern, version}}. `initialize` always selects
  # the legacy lifecycle.
  defp era("initialize", _params, _headers), do: {:ok, {:legacy, nil}}

  defp era(_method, params, headers) do
    case meta_version(params) do
      nil -> legacy_era(headers)
      @modern -> {:ok, {:modern, @modern}}
      version when version in @legacy -> {:ok, {:legacy, version}}
      other -> {:error, unsupported(other)}
    end
  end

  # A `_meta` that is not an object carries no version.
  defp meta_version(%{"_meta" => meta}) when is_map(meta), do: Map.get(meta, @meta_version)
  defp meta_version(_params), do: nil

  defp legacy_era(headers) do
    case Map.get(headers, "mcp-protocol-version") do
      nil -> {:ok, {:legacy, "2025-03-26"}}
      version when version in @legacy -> {:ok, {:legacy, version}}
      other -> {:error, unsupported(other)}
    end
  end

  defp unsupported(requested) do
    {400, -32_022, "Unsupported protocol version",
     %{"supported" => @supported, "requested" => requested_value(requested)}}
  end

  defp requested_value(value) when is_binary(value), do: String.slice(value, 0, 40)
  defp requested_value(value), do: Json.safe(value)

  defp check_headers({:legacy, _version}, _method, _params, _headers), do: :ok

  defp check_headers({:modern, version}, method, params, headers) do
    expected = [
      {"mcp-protocol-version", version},
      {"mcp-method", method} | name_header(method, params)
    ]

    case Enum.find(expected, fn {header, value} -> Map.get(headers, header) != value end) do
      nil -> :ok
      {header, _value} -> {:error, {400, -32_020, "Header mismatch: #{header}", nil}}
    end
  end

  defp name_header("tools/call", %{"name" => name}) when is_binary(name), do: [{"mcp-name", name}]
  defp name_header(_method, _params), do: []

  # Notifications have no id: acknowledged, never answered.
  defp dispatch(message, method, params, era, opts) do
    case Map.has_key?(message, "id") do
      false -> {202, nil}
      true -> respond(id_of(message), method, params, era, opts)
    end
  end

  defp respond(id, "initialize", params, _era, opts) do
    requested = Map.get(params, "protocolVersion")
    version = negotiate(requested)

    ok(id, %{
      "protocolVersion" => version,
      "capabilities" => capabilities(),
      "serverInfo" => server_info(opts),
      "instructions" => @instructions
    })
  end

  defp respond(id, "ping", _params, _era, _opts), do: ok(id, %{})

  defp respond(id, "server/discover", _params, {:modern, _version}, opts) do
    ok(id, %{
      "supportedVersions" => @supported,
      "capabilities" => capabilities(),
      "instructions" => @instructions,
      "_meta" => %{@server_info_key => server_info(opts)}
    })
  end

  defp respond(id, "tools/list", _params, era, _opts) do
    ok(id, complete(%{"tools" => Tools.list()}, era))
  end

  defp respond(id, "tools/call", %{"name" => name} = params, era, opts) when is_binary(name) do
    arguments = Map.get(params, "arguments")

    case Tools.call(name, arguments, opts) do
      :unknown_tool ->
        error(200, id, -32_602, "Unknown tool: " <> inspect(String.slice(name, 0, 60)))

      {:ok, structured} ->
        ok(id, complete(tool_result(name, structured, era), era))

      {:error, message} ->
        result = %{"content" => [text(message)], "isError" => true}
        ok(id, complete(result, era))
    end
  end

  defp respond(id, "tools/call", _params, _era, _opts) do
    error(200, id, -32_602, "Invalid params: name is required")
  end

  defp respond(id, method, _params, era, _opts) do
    error(
      unknown_method_status(era),
      id,
      -32_601,
      "Method not found: " <> inspect(String.slice(method, 0, 60))
    )
  end

  defp negotiate(requested) when requested in @legacy, do: requested
  defp negotiate(_requested), do: hd(@legacy)

  defp unknown_method_status({:modern, _version}), do: 404
  defp unknown_method_status(_era), do: 200

  defp maybe_data(error, nil), do: error
  defp maybe_data(error, data), do: Map.put(error, "data", data)

  defp tool_result(name, structured, era) do
    result = %{"content" => [text(tool_text(name, structured))], "isError" => false}

    case structured_content?(era) do
      true -> Map.put(result, "structuredContent", structured)
      false -> result
    end
  end

  # The text block is the JSON of the result, except for page_report: its
  # Markdown (also in structuredContent) reads better as plain text.
  defp tool_text("page_report", %{"markdown" => markdown}), do: markdown
  defp tool_text(_name, structured), do: Json.encode!(structured)

  # 2025-03-26 (also: no header at all) predates structuredContent.
  defp structured_content?({_era, "2025-03-26"}), do: false
  defp structured_content?(_era), do: true

  defp complete(result, {:modern, _version}), do: Map.put(result, "resultType", "complete")
  defp complete(result, _era), do: result

  defp text(text), do: %{"type" => "text", "text" => text}

  defp capabilities, do: %{"tools" => %{"listChanged" => false}}

  defp server_info(opts) do
    %{"name" => "phoenix_dev_toolbar", "version" => Keyword.get(opts, :server_version, "0.0.0")}
  end

  defp ok(id, result), do: {200, %{"jsonrpc" => "2.0", "id" => id, "result" => result}}

  defp error(status, id, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = maybe_data(error, data)
    {status, %{"jsonrpc" => "2.0", "id" => id, "error" => error}}
  end
end
