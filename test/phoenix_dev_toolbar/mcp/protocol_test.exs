defmodule PhoenixDevToolbar.Mcp.ProtocolTest do
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.ReportFixtures

  alias PhoenixDevToolbar.Mcp.Json
  alias PhoenixDevToolbar.Mcp.Protocol
  alias PhoenixDevToolbar.Store

  @opts [base_url: "http://localhost:4000/__pdt", server_version: "1.2.3"]
  @meta "io.modelcontextprotocol/protocolVersion"
  @all ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
  end

  defp rpc(method, params \\ nil, id \\ 1) do
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    if params, do: Map.put(message, "params", params), else: message
  end

  defp modern(params), do: Map.put(params, "_meta", %{@meta => "2026-07-28"})

  defp modern_headers(method, name \\ nil) do
    base = %{"mcp-protocol-version" => "2026-07-28", "mcp-method" => method}
    if name, do: Map.put(base, "mcp-name", name), else: base
  end

  defp result!(response) do
    assert {200, %{"jsonrpc" => "2.0", "id" => 1, "result" => result}} = response
    result
  end

  describe "legacy era" do
    test "initialize answers the client's version when supported" do
      for version <- ["2025-03-26", "2025-06-18", "2025-11-25"] do
        result =
          result!(Protocol.handle(rpc("initialize", %{"protocolVersion" => version}), %{}, @opts))

        assert %{
                 "protocolVersion" => ^version,
                 "capabilities" => %{"tools" => %{"listChanged" => false}},
                 "serverInfo" => %{"name" => "phoenix_dev_toolbar", "version" => "1.2.3"},
                 "instructions" => instructions
               } = result

        assert instructions =~ "10 minutes"
      end
    end

    test "initialize falls back to 2025-11-25 for an unknown version" do
      result =
        result!(
          Protocol.handle(rpc("initialize", %{"protocolVersion" => "1999-01-01"}), %{}, @opts)
        )

      assert result["protocolVersion"] == "2025-11-25"
      result = result!(Protocol.handle(rpc("initialize"), %{}, @opts))
      assert result["protocolVersion"] == "2025-11-25"
    end

    test "initialize with modern _meta is still legacy" do
      params = modern(%{"protocolVersion" => "2025-06-18"})
      result = result!(Protocol.handle(rpc("initialize", params), %{}, @opts))
      assert result["protocolVersion"] == "2025-06-18"
      refute Map.has_key?(result, "resultType")
    end

    test "notifications get 202 and no body" do
      note = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      assert Protocol.handle(note, %{}, @opts) == {202, nil}
    end

    test "ping" do
      assert result!(Protocol.handle(rpc("ping"), %{}, @opts)) == %{}
    end

    test "tools/list" do
      result =
        result!(
          Protocol.handle(rpc("tools/list"), %{"mcp-protocol-version" => "2025-06-18"}, @opts)
        )

      assert length(result["tools"]) == 7
      refute Map.has_key?(result, "resultType")
    end

    test "unknown method is a 200 with -32_601" do
      assert {200, %{"id" => 1, "error" => %{"code" => -32_601}}} =
               Protocol.handle(rpc("nope"), %{}, @opts)

      assert {200, %{"error" => %{"code" => -32_601}}} =
               Protocol.handle(rpc("server/discover"), %{}, @opts)
    end

    test "an unsupported header version is 400 with -32_022" do
      headers = %{"mcp-protocol-version" => "1999-01-01"}

      assert {400, %{"error" => %{"code" => -32_022, "data" => data}}} =
               Protocol.handle(rpc("tools/list"), headers, @opts)

      assert data == %{"supported" => @all, "requested" => "1999-01-01"}
    end

    test "tools/call ok carries structuredContent and the same JSON as text" do
      session(:request, path: "/users")
      params = %{"name" => "list_pages", "arguments" => %{}}
      headers = %{"mcp-protocol-version" => "2025-06-18"}

      result = result!(Protocol.handle(rpc("tools/call", params), headers, @opts))

      assert %{
               "isError" => false,
               "structuredContent" => %{"pages" => [_]},
               "content" => [%{"type" => "text", "text" => text}]
             } =
               result

      assert {:ok, decoded} = Json.decode(text)
      assert decoded == result["structuredContent"]
      # The whole response is encodable.
      assert byte_size(Json.encode!(result)) > 0
    end

    test "2025-03-26 (or no header) omits structuredContent" do
      params = %{"name" => "list_pages"}

      for headers <- [%{}, %{"mcp-protocol-version" => "2025-03-26"}] do
        result = result!(Protocol.handle(rpc("tools/call", params), headers, @opts))
        assert %{"isError" => false, "content" => [_]} = result
        refute Map.has_key?(result, "structuredContent")
      end
    end

    test "a tool error is an isError result" do
      params = %{"name" => "page_summary", "arguments" => %{}}
      result = result!(Protocol.handle(rpc("tools/call", params), %{}, @opts))

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "No page captured"
      refute Map.has_key?(result, "structuredContent")

      bad = %{"name" => "list_pages", "arguments" => %{"limit" => 0}}
      assert %{"isError" => true} = result!(Protocol.handle(rpc("tools/call", bad), %{}, @opts))
    end

    test "unknown tool and missing name are -32_602" do
      assert {200, %{"error" => %{"code" => -32_602}}} =
               Protocol.handle(rpc("tools/call", %{"name" => "nope"}), %{}, @opts)

      assert {200, %{"error" => %{"code" => -32_602}}} =
               Protocol.handle(rpc("tools/call", %{}), %{}, @opts)
    end
  end

  describe "modern era (2026-07-28)" do
    test "server/discover" do
      params = modern(%{})

      result =
        result!(
          Protocol.handle(
            rpc("server/discover", params),
            modern_headers("server/discover"),
            @opts
          )
        )

      assert result["supportedVersions"] == @all
      assert result["capabilities"] == %{"tools" => %{"listChanged" => false}}
      assert result["instructions"] =~ "page_summary"

      assert result["_meta"]["io.modelcontextprotocol/serverInfo"] ==
               %{"name" => "phoenix_dev_toolbar", "version" => "1.2.3"}
    end

    test "tools/list and tools/call add resultType complete" do
      list =
        result!(
          Protocol.handle(rpc("tools/list", modern(%{})), modern_headers("tools/list"), @opts)
        )

      assert list["resultType"] == "complete"

      params = modern(%{"name" => "list_pages", "arguments" => %{}})

      call =
        result!(
          Protocol.handle(
            rpc("tools/call", params),
            modern_headers("tools/call", "list_pages"),
            @opts
          )
        )

      assert %{
               "resultType" => "complete",
               "isError" => false,
               "structuredContent" => %{"pages" => []}
             } = call

      failing = modern(%{"name" => "page_summary"})

      err =
        result!(
          Protocol.handle(
            rpc("tools/call", failing),
            modern_headers("tools/call", "page_summary"),
            @opts
          )
        )

      assert %{"resultType" => "complete", "isError" => true} = err
    end

    test "ping" do
      assert result!(Protocol.handle(rpc("ping", modern(%{})), modern_headers("ping"), @opts)) ==
               %{}
    end

    test "header mismatch is 400 with -32_020" do
      params = modern(%{"name" => "list_pages"})
      good = modern_headers("tools/call", "list_pages")

      for headers <- [
            Map.put(good, "mcp-protocol-version", "2025-06-18"),
            Map.put(good, "mcp-method", "tools/list"),
            Map.put(good, "mcp-name", "page_summary"),
            Map.delete(good, "mcp-name"),
            %{}
          ] do
        assert {400, %{"error" => %{"code" => -32_020}}} =
                 Protocol.handle(rpc("tools/call", params), headers, @opts)
      end
    end

    test "unsupported version in _meta is 400 with -32_022" do
      params = %{"_meta" => %{@meta => "2030-01-01"}}

      assert {400,
              %{
                "error" => %{
                  "code" => -32_022,
                  "data" => %{"supported" => @all, "requested" => "2030-01-01"}
                }
              }} =
               Protocol.handle(rpc("tools/list", params), %{}, @opts)
    end

    test "unknown method is 404 with -32_601" do
      assert {404, %{"error" => %{"code" => -32_601}}} =
               Protocol.handle(rpc("nope", modern(%{})), modern_headers("nope"), @opts)
    end

    test "notifications still get 202" do
      note = %{"jsonrpc" => "2.0", "method" => "notifications/x", "params" => modern(%{})}
      assert Protocol.handle(note, modern_headers("notifications/x"), @opts) == {202, nil}
    end
  end

  describe "malformed input" do
    test "parse error" do
      assert {400, %{"id" => nil, "error" => %{"code" => -32_700}}} =
               Protocol.handle({:error, :parse}, %{}, @opts)
    end

    test "batches are rejected" do
      assert {400, %{"error" => %{"code" => -32_600}}} =
               Protocol.handle([rpc("ping")], %{}, @opts)

      assert {400, %{"error" => %{"code" => -32_600}}} = Protocol.handle([], %{}, @opts)
    end

    test "invalid requests" do
      for message <- [
            1,
            "x",
            nil,
            %{},
            %{"jsonrpc" => "1.0", "method" => "ping", "id" => 1},
            %{"jsonrpc" => "2.0", "id" => 1}
          ] do
        assert {400, %{"error" => %{"code" => -32_600}}} = Protocol.handle(message, %{}, @opts)
      end

      assert {400, %{"error" => %{"code" => -32_600}}} =
               Protocol.handle(rpc("ping", nil, %{"x" => 1}), %{}, @opts)
    end
  end
end
