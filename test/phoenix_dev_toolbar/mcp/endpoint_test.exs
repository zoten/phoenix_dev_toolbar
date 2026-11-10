defmodule PhoenixDevToolbar.Mcp.EndpointTest do
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.EnvHelpers
  import PhoenixDevToolbar.ReportFixtures
  import Plug.Conn
  import Plug.Test

  alias PhoenixDevToolbar.Mcp.Json
  alias PhoenixDevToolbar.Plug, as: ToolbarPlug
  alias PhoenixDevToolbar.Store

  @opts ToolbarPlug.init([])
  @meta "io.modelcontextprotocol/protocolVersion"

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
  end

  defp rpc(method, params \\ nil, id \\ 1) do
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    if params, do: Map.put(message, "params", params), else: message
  end

  defp post(body, headers \\ []) do
    body = if is_binary(body), do: body, else: Json.encode!(body)

    conn = %{conn(:post, "/__pdt/mcp", body) | host: "localhost"}
    conn = put_req_header(conn, "content-type", "application/json")

    headers
    |> Enum.reduce(conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
    |> ToolbarPlug.call(@opts)
  end

  defp json(conn), do: Json.decode(conn.resp_body) |> elem(1)

  describe "guards" do
    test "404 when mcp: false" do
      put_app_env(:mcp, false)
      conn = post(rpc("ping"))
      assert conn.status == 404
      assert conn.halted
      assert conn.resp_body =~ "mcp"
    end

    test "403 for a foreign host" do
      conn = %{conn(:post, "/__pdt/mcp", "{}") | host: "evil.example"}
      conn = conn |> put_req_header("content-type", "application/json") |> ToolbarPlug.call(@opts)
      assert conn.status == 403
      assert conn.resp_body =~ "allowed_hosts"
    end

    defp from(ip, headers \\ []) do
      conn = %{conn(:post, "/__pdt/mcp", Json.encode!(rpc("ping"))) | host: "localhost"}
      conn = %{conn | remote_ip: ip}
      conn = put_req_header(conn, "content-type", "application/json")

      headers
      |> Enum.reduce(conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
      |> ToolbarPlug.call(@opts)
    end

    test "403 for a foreign peer by default, naming the option" do
      conn = from({203, 0, 113, 9})
      assert conn.status == 403
      assert conn.resp_body =~ "mcp: [clients: [...]]"
    end

    defp from_own(ip, headers \\ []) do
      conn = %{conn(:post, "/__pdt/mcp", Json.encode!(rpc("ping"))) | host: "localhost"}
      conn = %{conn | remote_ip: ip}
      conn = put_req_header(conn, "content-type", "application/json")

      headers
      |> Enum.reduce(conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
      |> PhoenixDevToolbar.Mcp.Endpoint.call("/__pdt", fn -> [{192, 168, 7, 7}] end)
    end

    test "a peer on one of this machine's own addresses is accepted, others refused" do
      assert from_own({192, 168, 7, 7}).status == 200
      assert from_own({192, 168, 7, 8}).status == 403
    end

    test "an own-address peer with a proxy header is refused in :local" do
      assert from_own({192, 168, 7, 7}, [{"x-forwarded-for", "1.2.3.4"}]).status == 403
    end

    test "the Origin guard applies under clients: :any and under a list" do
      put_app_env(:mcp, clients: :any)
      assert from({203, 0, 113, 9}, [{"origin", "http://evil.example"}]).status == 403

      put_app_env(:mcp, clients: ["203.0.113.0/24"])
      assert from({203, 0, 113, 9}, [{"origin", "http://evil.example"}]).status == 403
      assert from({203, 0, 113, 9}).status == 200
    end

    test "a clients list admits matching peers only, and still refuses proxy headers" do
      put_app_env(:mcp, clients: ["203.0.113.0/24", "fd00::/8"])
      assert from({203, 0, 113, 9}).status == 200
      assert from({0xFD00, 0, 0, 0, 0, 0, 0, 1}).status == 200
      assert from({203, 0, 114, 9}).status == 403
      assert from({203, 0, 113, 9}, [{"x-forwarded-for", "1.2.3.4"}]).status == 403
    end

    test "clients: :any accepts any peer and proxy headers" do
      put_app_env(:mcp, clients: :any)
      assert from({203, 0, 113, 9}).status == 200
      assert from({203, 0, 113, 9}, [{"x-forwarded-for", "1.2.3.4"}]).status == 200
    end

    test "clients: :any still applies the Host guard" do
      put_app_env(:mcp, clients: :any)

      conn = %{
        conn(:post, "/__pdt/mcp", "{}")
        | host: "evil.example",
          remote_ip: {203, 0, 113, 9}
      }

      conn = conn |> put_req_header("content-type", "application/json") |> ToolbarPlug.call(@opts)
      assert conn.status == 403
    end

    test "403 behind a proxy header" do
      for name <- ["x-forwarded-for", "x-forwarded-host", "x-real-ip", "forwarded"] do
        assert post(rpc("ping"), [{name, "1.2.3.4"}]).status == 403, name
      end
    end

    test "origin: foreign refused, same and allowed ok, none ok" do
      assert post(rpc("ping"), [{"origin", "http://evil.example"}]).status == 403
      assert post(rpc("ping"), [{"origin", "http://localhost"}]).status == 200
      assert post(rpc("ping")).status == 200

      put_app_env(:allowed_origins, ["https://abc.tunnel.example"])
      assert post(rpc("ping"), [{"origin", "https://abc.tunnel.example"}]).status == 200
    end

    test "Origin: null and a foreign origin on text/plain are refused before the content type" do
      assert post(rpc("ping"), [{"origin", "null"}]).status == 403

      conn = %{conn(:post, "/__pdt/mcp", "{}") | host: "localhost"}

      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> put_req_header("origin", "http://evil.example")
        |> ToolbarPlug.call(@opts)

      assert conn.status == 403
    end

    test "IPv6 loopback peers are accepted" do
      for ip <- [{0, 0, 0, 0, 0, 0, 0, 1}, {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}] do
        conn = %{conn(:post, "/__pdt/mcp", Json.encode!(rpc("ping"))) | host: "localhost"}
        conn = %{conn | remote_ip: ip}

        conn =
          conn |> put_req_header("content-type", "application/json") |> ToolbarPlug.call(@opts)

        assert conn.status == 200, inspect(ip)
      end
    end

    test "405 for other methods, with allow" do
      for method <- [:get, :delete] do
        conn = %{conn(method, "/__pdt/mcp") | host: "localhost"} |> ToolbarPlug.call(@opts)
        assert conn.status == 405
        assert get_resp_header(conn, "allow") == ["POST"]
      end
    end

    test "415 for another content type" do
      conn = %{conn(:post, "/__pdt/mcp", "{}") | host: "localhost"}
      conn = conn |> put_req_header("content-type", "text/plain") |> ToolbarPlug.call(@opts)
      assert conn.status == 415
    end

    test "413 over 1 MB" do
      assert post(String.duplicate("a", 1_000_001)).status == 413
    end

    test "invalid JSON is 400 with -32700" do
      conn = post("{nope")
      assert conn.status == 400
      assert %{"error" => %{"code" => -32_700}} = json(conn)
    end

    test "a body already parsed by the host is used" do
      conn = %{conn(:post, "/__pdt/mcp", "") | host: "localhost"}
      conn = put_req_header(conn, "content-type", "application/json")
      conn = %{conn | body_params: rpc("ping")} |> ToolbarPlug.call(@opts)
      assert conn.status == 200
      assert %{"id" => 1, "result" => %{}} = json(conn)

      conn = %{conn(:post, "/__pdt/mcp", "") | host: "localhost"}
      conn = put_req_header(conn, "content-type", "application/json")
      conn = %{conn | body_params: %{"_json" => [rpc("ping")]}} |> ToolbarPlug.call(@opts)
      assert conn.status == 400
      assert %{"error" => %{"code" => -32_600}} = json(conn)
    end
  end

  describe "malformed input" do
    test "a non object _meta is a 400, never a 500" do
      for meta <- ["str", 1, [1], nil] do
        conn = post(rpc("tools/list", %{"_meta" => meta}))
        assert conn.status == 200, inspect(meta)
      end

      conn = post(rpc("tools/list", %{"_meta" => %{@meta => "1999-01-01"}}))
      assert conn.status == 400
      assert %{"error" => %{"code" => -32_022}} = json(conn)

      assert post(rpc("tools/list", "params-as-string")).status == 200
      assert post(%{"jsonrpc" => "2.0", "id" => 1, "method" => 5}).status == 400
      assert post(%{"jsonrpc" => "2.0", "id" => %{}, "method" => "ping"}).status == 400
    end

    @tag :capture_log
    test "a failure while encoding is a static 500 with -32603" do
      defmodule BoomJson do
        @moduledoc false
        def encode_to_iodata!(_term), do: raise("boom")
        defdelegate decode(binary), to: Jason
      end

      previous = Application.fetch_env(:phoenix, :json_library)
      Application.put_env(:phoenix, :json_library, BoomJson)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phoenix, :json_library, value)
          :error -> Application.delete_env(:phoenix, :json_library)
        end
      end)

      conn = post(~s({"jsonrpc":"2.0","id":1,"method":"ping"}))
      assert conn.status == 500
      assert conn.halted
      assert [<<"application/json", _::binary>>] = get_resp_header(conn, "content-type")
      assert %{"error" => %{"code" => -32_603}} = Jason.decode!(conn.resp_body)
    end
  end

  describe "flows" do
    test "legacy: initialize, initialized, tools/list, tools/call" do
      session = session(:request, path: "/users")
      query(session)

      conn = post(rpc("initialize", %{"protocolVersion" => "2025-06-18"}))
      assert conn.status == 200
      assert %{"result" => %{"protocolVersion" => "2025-06-18"}} = json(conn)

      conn = post(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      assert conn.status == 202
      assert conn.resp_body == ""

      conn = post(rpc("tools/list"))
      assert %{"result" => %{"tools" => tools}} = json(conn)
      assert "page_summary" in Enum.map(tools, & &1["name"])

      conn =
        post(
          rpc("tools/call", %{"name" => "page_summary", "arguments" => %{"sid" => session.sid}})
        )

      assert conn.status == 200

      assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} = json(conn)
      assert {:ok, %{"queries" => %{"count" => 1}}} = Json.decode(text)
    end

    test "modern tools/call with headers and _meta" do
      session = session(:request, path: "/users")

      params = %{
        "name" => "page_summary",
        "arguments" => %{"sid" => session.sid},
        "_meta" => %{@meta => "2026-07-28"}
      }

      conn =
        post(rpc("tools/call", params), [
          {"mcp-protocol-version", "2026-07-28"},
          {"mcp-method", "tools/call"},
          {"mcp-name", "page_summary"}
        ])

      assert conn.status == 200
      assert %{"result" => %{"resultType" => "complete", "isError" => false}} = json(conn)
    end

    test "modern header mismatch is 400" do
      params = %{"name" => "page_summary", "_meta" => %{@meta => "2026-07-28"}}

      conn =
        post(rpc("tools/call", params), [
          {"mcp-protocol-version", "2026-07-28"},
          {"mcp-method", "tools/list"},
          {"mcp-name", "page_summary"}
        ])

      assert conn.status == 400
    end
  end

  describe "response hygiene" do
    test "headers, stripped CORS, and no session for the request itself" do
      conn =
        %{conn(:post, "/__pdt/mcp", Json.encode!(rpc("ping"))) | host: "localhost"}
        |> put_req_header("content-type", "application/json")
        |> put_resp_header("access-control-allow-origin", "*")
        |> ToolbarPlug.call(@opts)

      assert [<<"application/json", _::binary>>] = get_resp_header(conn, "content-type")
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert Store.sessions() == []
      assert PhoenixDevToolbar.Attribution.tracked_sid() == nil

      refused = post(rpc("ping"), [{"x-real-ip", "1.1.1.1"}])
      assert [<<"text/plain", _::binary>>] = get_resp_header(refused, "content-type")
      assert get_resp_header(refused, "cache-control") == ["no-store"]
    end

    test "CORS headers are stripped on refusals too" do
      cors = fn conn -> put_resp_header(conn, "access-control-allow-origin", "*") end

      forbidden =
        %{conn(:post, "/__pdt/mcp", "{}") | host: "evil.example"}
        |> cors.()
        |> ToolbarPlug.call(@opts)

      assert forbidden.status == 403
      assert get_resp_header(forbidden, "access-control-allow-origin") == []

      not_allowed =
        %{conn(:get, "/__pdt/mcp") | host: "localhost"} |> cors.() |> ToolbarPlug.call(@opts)

      assert not_allowed.status == 405
      assert get_resp_header(not_allowed, "access-control-allow-origin") == []
    end

    test "panel_url is absolute" do
      session = session(:request, path: "/users")

      conn =
        post(
          rpc("tools/call", %{"name" => "page_summary", "arguments" => %{"sid" => session.sid}})
        )

      assert %{"result" => %{"content" => [%{"text" => text}]}} = json(conn)
      assert {:ok, %{"panel_url" => url}} = Json.decode(text)
      assert url == "http://localhost:80/__pdt/panel?sid=" <> session.sid
    end

    test "a custom :path moves the endpoint and the panel_url" do
      opts = ToolbarPlug.init(path: "/dev/tb")
      session = session(:request, path: "/users")

      body =
        rpc("tools/call", %{"name" => "page_summary", "arguments" => %{"sid" => session.sid}})

      conn =
        %{conn(:post, "/dev/tb/mcp", Json.encode!(body)) | host: "localhost"}
        |> put_req_header("content-type", "application/json")
        |> ToolbarPlug.call(opts)

      assert conn.status == 200
      assert %{"result" => %{"content" => [%{"text" => text}]}} = json(conn)
      assert {:ok, %{"panel_url" => url}} = Json.decode(text)
      assert String.starts_with?(url, "http://localhost:80/dev/tb/panel")

      old = %{conn(:post, "/__pdt/mcp", "{}") | host: "localhost"} |> ToolbarPlug.call(opts)
      refute old.halted
      assert old.state == :unset
    end

    test "untouched when the toolbar is disabled" do
      put_app_env(:enabled, false)
      conn = %{conn(:post, "/__pdt/mcp", "{}") | host: "localhost"} |> ToolbarPlug.call(@opts)
      refute conn.halted
      assert conn.state == :unset
    end
  end
end
