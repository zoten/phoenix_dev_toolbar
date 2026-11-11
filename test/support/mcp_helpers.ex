defmodule PhoenixDevToolbar.McpHelpers do
  @moduledoc false
  # JSON-RPC messages, the modern protocol era markers and MCP requests through
  # the toolbar plug or the host endpoint.

  import ExUnit.Assertions
  import Phoenix.ConnTest, only: [build_conn: 0, json_response: 2, post: 3]
  import Plug.Conn
  import Plug.Test, only: [conn: 3]

  alias PhoenixDevToolbar.Mcp.Json
  alias PhoenixDevToolbar.Plug, as: ToolbarPlug

  @endpoint DemoWeb.Endpoint
  @meta "io.modelcontextprotocol/protocolVersion"

  @doc "A JSON-RPC 2.0 request message."
  @spec rpc(String.t(), map() | String.t() | nil, term()) :: map()
  def rpc(method, params \\ nil, id \\ 1) do
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    if params, do: Map.put(message, "params", params), else: message
  end

  @doc "`params` with the modern era `_meta` protocol version."
  @spec modern(map()) :: map()
  def modern(params), do: Map.put(params, "_meta", %{@meta => "2026-07-28"})

  @doc "The modern era `mcp-*` request headers for `method` (and `name`)."
  @spec modern_headers(String.t(), String.t() | nil) :: %{String.t() => String.t()}
  def modern_headers(method, name \\ nil) do
    base = %{"mcp-protocol-version" => "2026-07-28", "mcp-method" => method}
    if name, do: Map.put(base, "mcp-name", name), else: base
  end

  @doc """
  An MCP request conn, not yet dispatched. `body` is a binary or a term
  encoded as JSON.

  Options: `:host` (`"localhost"`), `:remote_ip`, `:headers` (a list of
  `{name, value}`), `:content_type` (`"application/json"`, `nil` for none),
  `:scheme`, `:port`, `:method` (`:post`), `:path` (`"/__pdt/mcp"`).
  """
  @spec build_mcp_conn(term(), keyword()) :: Plug.Conn.t()
  def build_mcp_conn(body, opts \\ []) do
    body = if is_binary(body), do: body, else: Json.encode!(body)

    conn = %{
      conn(Keyword.get(opts, :method, :post), Keyword.get(opts, :path, "/__pdt/mcp"), body)
      | host: Keyword.get(opts, :host, "localhost")
    }

    conn = Enum.reduce(~w(remote_ip scheme port)a, conn, &put_field(&2, &1, opts))

    conn =
      case Keyword.get(opts, :content_type, "application/json") do
        nil -> conn
        type -> put_req_header(conn, "content-type", type)
      end

    opts
    |> Keyword.get(:headers, [])
    |> Enum.reduce(conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
  end

  @doc """
  An MCP request through `PhoenixDevToolbar.Plug`: `build_mcp_conn/2` options
  plus `:plug_opts` (`ToolbarPlug.init([])`).
  """
  @spec mcp_conn(term(), keyword()) :: Plug.Conn.t()
  def mcp_conn(body, opts \\ []) do
    {plug_opts, opts} = Keyword.pop_lazy(opts, :plug_opts, fn -> ToolbarPlug.init([]) end)
    body |> build_mcp_conn(opts) |> ToolbarPlug.call(plug_opts)
  end

  @doc "A tool call through the host endpoint: the structured result."
  @spec mcp_call(String.t(), map()) :: map()
  def mcp_call(name, arguments) do
    body = rpc("tools/call", %{"name" => name, "arguments" => arguments})

    conn =
      %{build_conn() | host: "localhost", remote_ip: {127, 0, 0, 1}}
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", "2025-06-18")
      |> post("/__pdt/mcp", Jason.encode!(body))

    _ =
      assert %{"result" => %{"isError" => false, "structuredContent" => result}} =
               json_response(conn, 200)

    result
  end

  defp put_field(conn, field, opts) do
    case Keyword.fetch(opts, field) do
      {:ok, value} -> Map.put(conn, field, value)
      :error -> conn
    end
  end
end
