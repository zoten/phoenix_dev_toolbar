defmodule PhoenixDevToolbar.Mcp.ToolsTest do
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.ReportFixtures
  import PhoenixDevToolbar.StackArgsHelpers

  alias PhoenixDevToolbar.Mcp.Json
  alias PhoenixDevToolbar.Mcp.Tools
  alias PhoenixDevToolbar.Store

  @opts [base_url: "http://localhost:4000/__pdt"]
  @t0 1_800_000_000_000_000

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
  end

  defp call!(name, args \\ %{}) do
    assert {:ok, result} = Tools.call(name, args, @opts)
    # Always encodable.
    assert byte_size(Json.encode!(result)) > 0
    result
  end

  defp call_error(name, args) do
    assert {:error, message} = Tools.call(name, args, @opts)
    message
  end

  test "list/0 describes six read-only tools with strict schemas" do
    tools = Tools.list()

    assert Enum.map(tools, & &1["name"]) ==
             ~w(list_pages page_summary page_queries page_callbacks page_n_plus_one page_errors)

    for tool <- tools do
      assert tool["annotations"] == %{"readOnlyHint" => true}
      assert tool["inputSchema"]["additionalProperties"] == false
      assert is_binary(tool["title"]) and is_binary(tool["description"])
    end
  end

  test "unknown tool" do
    assert Tools.call("nope", %{}, @opts) == :unknown_tool
    assert Tools.call(:atom, %{}, @opts) == :unknown_tool
  end

  describe "list_pages" do
    test "oversized path and path_prefix are tool errors" do
      big = String.duplicate("a", 2049)
      assert call_error("list_pages", %{"path_prefix" => big}) =~ "2048"
      assert call_error("list_pages", %{"path" => big}) =~ "2048"
      assert call_error("page_summary", %{"path" => big}) =~ "2048"

      assert %{"pages" => []} =
               call!("list_pages", %{"path_prefix" => String.duplicate("a", 2048)})
    end

    test "a connected mount is part of its request, navigated and orphan LiveViews are pages" do
      req = session(:request, path: "/a", started_at: @t0)
      _mount = session(:live_view, path: "/a", parent: req.sid, started_at: @t0 + 1)
      nav = session(:live_view, path: "/b", parent: "gone-lv", started_at: @t0 + 2)
      orphan = session(:live_view, path: "/c", started_at: @t0 + 3)
      nav2 = session(:live_view, path: "/d", parent: nav.sid, started_at: @t0 + 4)

      assert %{"pages" => pages} = call!("list_pages")
      assert Enum.map(pages, & &1["sid"]) == [nav2.sid, orphan.sid, nav.sid, req.sid]

      # The limit counts pages, not filtered out mounts.
      assert %{"pages" => [_, _, _, _]} = call!("list_pages", %{"limit" => 4})
      assert %{"pages" => [%{"sid" => sid}]} = call!("list_pages", %{"path_prefix" => "/a"})
      assert sid == req.sid
    end

    test "lists newest first with a panel_url, honours path_prefix and limit" do
      a = session(:request, path: "/users", started_at: @t0)
      b = session(:request, path: "/users/1", started_at: @t0 + 1)
      _c = session(:request, path: "/posts", started_at: @t0 + 2)

      assert %{"pages" => [%{"sid" => sid, "panel_url" => url}, %{"sid" => sid2}]} =
               call!("list_pages", %{"path_prefix" => "/users"})

      assert {sid, sid2} == {b.sid, a.sid}
      assert url == "http://localhost:4000/__pdt/panel?sid=" <> b.sid
      assert %{"pages" => [_]} = call!("list_pages", %{"limit" => 1})
      assert %{"pages" => [%{"path" => "/posts"}]} = call!("list_pages", %{"path" => "/posts"})
    end

    test "since takes a sid or an ISO 8601 time and lists only later pages" do
      a = session(:request, path: "/a", started_at: @t0)
      b = session(:request, path: "/b", started_at: @t0 + 5_000_000)
      c = session(:request, path: "/c", started_at: @t0 + 9_000_000)

      assert %{"pages" => pages} = call!("list_pages", %{"since" => a.sid})
      assert Enum.map(pages, & &1["sid"]) == [c.sid, b.sid]
      assert [%{"started_at" => started}, _] = pages
      assert {:ok, _dt, 0} = DateTime.from_iso8601(started)

      iso = DateTime.to_iso8601(DateTime.from_unix!(@t0 + 5_000_000, :microsecond))
      assert %{"pages" => [%{"sid" => sid}]} = call!("list_pages", %{"since" => iso})
      assert sid == c.sid

      msg = call_error("list_pages", %{"since" => "unknown-sid"})
      assert msg =~ "no longer captured" and msg =~ "started_at" and msg =~ "ISO 8601"
      assert call_error("list_pages", %{"since" => "2026-11-11"}) =~ "no longer captured"
    end

    test "an invalid since is a tool error saying what is accepted" do
      msg = call_error("list_pages", %{"since" => "not a time!"})
      assert msg =~ "since" and msg =~ "ISO 8601" and msg =~ "sid"
      assert call_error("list_pages", %{"since" => 5}) =~ "since"
    end

    test "path and path_prefix together are a tool error" do
      msg = call_error("list_pages", %{"path" => "/a", "path_prefix" => "/b"})
      assert msg == "Use path or path_prefix, not both."
    end

    test "a missing Store gives an empty list, not a crash" do
      :ok = Supervisor.terminate_child(PhoenixDevToolbar.Supervisor, Store)
      on_exit(fn -> Supervisor.restart_child(PhoenixDevToolbar.Supervisor, Store) end)

      assert %{"pages" => []} = call!("list_pages")
    end

    test "empty store gives an empty list" do
      assert call!("list_pages") == %{"pages" => []}
    end

    test "rejects invalid arguments" do
      assert call_error("list_pages", %{"limit" => 0}) =~ "limit"
      assert call_error("list_pages", %{"limit" => 51}) =~ "limit"
      assert call_error("list_pages", %{"limit" => "5"}) =~ "limit"
      assert call_error("list_pages", %{"path" => 1}) =~ "path"
      assert call_error("list_pages", %{"bogus" => 1}) =~ "bogus"
      assert call_error("list_pages", [1]) =~ "object"
    end
  end

  describe "page resolution" do
    test "sid wins over path, path wins over newest" do
      a = session(:request, path: "/a", started_at: @t0)
      b = session(:request, path: "/b", started_at: @t0 + 1)

      assert %{"session" => %{"sid" => sid}} =
               call!("page_summary", %{"sid" => a.sid, "path" => "/b"})

      assert sid == a.sid
      assert %{"session" => %{"sid" => sid}} = call!("page_summary", %{"path" => "/a"})
      assert sid == a.sid
      assert %{"session" => %{"sid" => sid}} = call!("page_summary")
      assert sid == b.sid
    end

    test "a connected mount resolves to its request" do
      root = session(:request, path: "/a", started_at: @t0)
      session(:live_view, path: "/a", parent: root.sid, started_at: @t0 + 1)

      assert %{"session" => %{"sid" => sid}} = call!("page_summary")
      assert sid == root.sid
    end

    test "no page, unknown sid and a malformed sid are errors with a hint" do
      assert call_error("page_summary", %{}) =~ "10 minutes"
      assert call_error("page_summary", %{"path" => "/x"}) =~ "No captured page at /x. list_pages"
      assert call_error("page_queries", %{"sid" => "unknown"}) =~ "No page captured"
      assert call_error("page_queries", %{"sid" => "../etc"}) =~ "sid must match"
      assert call_error("page_queries", %{"sid" => 5}) =~ "sid must be a string"
    end
  end

  describe "page_summary" do
    test "returns the Report summary with string keys and a panel_url" do
      s = session(:request, path: "/users")
      query(s)

      assert %{
               "queries" => %{"count" => 1},
               "panel_url" => url,
               "session" => %{"kind" => "request"}
             } =
               call!("page_summary", %{"sid" => s.sid})

      assert url == "http://localhost:4000/__pdt/panel?sid=" <> s.sid
    end

    test "is compact by default and verbose on request" do
      s = session(:request, path: "/users")
      query(s)

      assert %{"queries" => %{"slowest" => [item]}} = call!("page_summary", %{"sid" => s.sid})
      refute Map.has_key?(item, "sql")

      assert %{"queries" => %{"slowest" => [%{"sql" => _}]}} =
               call!("page_summary", %{"sid" => s.sid, "verbose" => true})

      assert call_error("page_summary", %{"verbose" => "yes"}) =~ "verbose must be a boolean"
    end
  end

  describe "page_callbacks sids" do
    test "a LiveView sid reads its own callbacks, the request sid its children too" do
      root = session(:request, path: "/users")
      mount = session(:live_view, path: "/users", parent: root.sid, started_at: @t0 + 1)
      callback(mount, :mount, span: 1, us: 10)
      callback(mount, :handle_event, span: 2, us: 20, event: "go")

      assert %{"callbacks" => own} = call!("page_callbacks", %{"sid" => mount.sid})
      assert Enum.map(own, & &1["callback"]) == ["mount", "handle_event"]
      assert Enum.all?(own, &(&1["sid"] == mount.sid))

      assert %{"callbacks" => all} = call!("page_callbacks", %{"sid" => root.sid})
      assert Enum.map(all, & &1["sid"]) == [mount.sid, mount.sid]
    end
  end

  describe "raw query data" do
    test "explain output never reaches page_summary or page_queries" do
      s = session(:request, path: "/users")
      query(s)

      for name <- ~w(page_summary page_queries) do
        result = call!(name, %{"sid" => s.sid})
        refute Json.encode!(result) =~ "raw-secret-param"
      end
    end
  end

  describe "page_queries" do
    setup do
      s = session(:request, path: "/users")
      query(s, sql: "SELECT 1", us: 50)
      query(s, sql: "SELECT 2", us: 900)
      query(s, sql: "SELECT 3", us: 300)
      {:ok, sid: s.sid}
    end

    test "total, returned and rows in order", %{sid: sid} do
      assert %{
               "total" => 3,
               "returned" => 2,
               "queries" => [%{"sql" => "SELECT 1"}, %{"sql" => "SELECT 2"}]
             } =
               call!("page_queries", %{"sid" => sid, "limit" => 2})
    end

    test "sort slowest", %{sid: sid} do
      assert %{
               "queries" => [
                 %{"sql" => "SELECT 2"},
                 %{"sql" => "SELECT 3"},
                 %{"sql" => "SELECT 1"}
               ]
             } =
               call!("page_queries", %{"sid" => sid, "sort" => "slowest"})
    end

    test "invalid limit and sort", %{sid: sid} do
      assert call_error("page_queries", %{"sid" => sid, "limit" => 201}) =~ "limit"
      assert call_error("page_queries", %{"sid" => sid, "sort" => "fastest"}) =~ "sort"
    end
  end

  describe "page_callbacks" do
    test "rows, slowest first, nil durations last" do
      s = session(:request, path: "/c")
      callback(s, :mount, us: 100)
      callback(s, :handle_event, event: "inc", us: 700)
      callback(s, :handle_info)

      assert %{
               "total" => 3,
               "callbacks" => [%{"callback" => "handle_event"}, %{"callback" => "mount"}, last]
             } =
               call!("page_callbacks", %{"sid" => s.sid, "sort" => "slowest"})

      assert last["callback"] == "handle_info"
      assert %{"callbacks" => [%{"view" => "DemoWeb.PageLive"} | _]} = call!("page_callbacks")
    end
  end

  describe "inferred handle_info" do
    test "page_callbacks lists them and page_summary counts unattributed queries" do
      s = session(:live_view, path: "/i")
      callback(s, :mount, span: 1, us: 100)
      query(s, span: 2, us: 30)

      assert %{
               "callbacks" => [
                 %{"inferred" => false},
                 %{"callback" => "handle_info", "inferred" => true}
               ]
             } =
               call!("page_callbacks", %{"sid" => s.sid})

      assert %{
               "unattributed" => %{"count" => 1, "total_us" => 30, "origins" => [%{"count" => 1}]}
             } =
               call!("page_summary", %{"sid" => s.sid})
    end
  end

  describe "page_n_plus_one" do
    test "reports repeated queries, or an empty list" do
      s = session(:request, path: "/n")
      assert %{"n_plus_one" => []} = call!("page_n_plus_one", %{"sid" => s.sid})

      for _ <- 1..12, do: query(s, sql: "SELECT * FROM posts WHERE user_id = ?")

      assert %{
               "n_plus_one" => [
                 %{"count" => count, "sql" => "SELECT * FROM posts WHERE user_id = ?"}
               ]
             } =
               call!("page_n_plus_one", %{"sid" => s.sid})

      assert count >= 5
    end
  end

  describe "page_errors" do
    test "lists failures with limit" do
      s = session(:request, path: "/e")
      callback(s, :handle_event, error: "boom", us: 10)
      callback(s, :handle_event, error: "bang", us: 10)

      assert %{"total" => 2, "returned" => 1, "errors" => [%{"message" => message}]} =
               call!("page_errors", %{"sid" => s.sid, "limit" => 1})

      assert message =~ "boom"
      assert call_error("page_errors", %{"limit" => 101}) =~ "limit"
    end

    test "stack_args only with agents: true (ADR 03)" do
      s = session(:request, path: "/e")

      callback(s, :handle_event,
        error: "boom",
        us: 10,
        stacktrace: ["MyLive.f/1"],
        stack_args: ["[\"ann\"]"]
      )

      put_stack_args(true)
      assert %{"errors" => [error]} = call!("page_errors", %{"sid" => s.sid})
      refute Map.has_key?(error, "stack_args")

      put_stack_args(agents: true)

      assert %{"errors" => [%{"stack_args" => ["[\"ann\"]"]}]} =
               call!("page_errors", %{"sid" => s.sid})
    end
  end
end
