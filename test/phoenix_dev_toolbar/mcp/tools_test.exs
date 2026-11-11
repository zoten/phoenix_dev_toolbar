defmodule PhoenixDevToolbar.Mcp.ToolsTest do
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.ReportFixtures
  import PhoenixDevToolbar.StackArgsHelpers

  alias PhoenixDevToolbar.Mcp.Json
  alias PhoenixDevToolbar.Mcp.Tools
  alias PhoenixDevToolbar.Session
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

  test "list/0 describes ten read-only tools with strict schemas" do
    tools = Tools.list()

    assert Enum.map(tools, & &1["name"]) ==
             ~w(list_pages page_summary page_queries page_callbacks page_n_plus_one page_errors recent_errors compare_pages page_report page_assigns_shape)

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

      # A 16-char sid (Session.new_sid/0 shape) that is gone.
      gone = Session.new_sid()
      msg = call_error("list_pages", %{"since" => gone})
      assert msg =~ "no longer captured" and msg =~ "started_at" and msg =~ "ISO 8601"
      assert call_error("recent_errors", %{"since" => gone}) =~ "no longer captured"

      # Anything else is not a sid at all.
      for value <- ["yesterday", "unknown-sid", "2026-11-11"] do
        msg = call_error("list_pages", %{"since" => value})
        assert msg =~ "not a captured page sid or an ISO 8601 time"
        refute msg =~ "no longer captured"
      end
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
      assert call_error("page_queries", %{"sid" => "../etc"}) =~ "sid: a page sid from list_pages"

      assert call_error("page_queries", %{"sid" => 5}) =~
               "sid: a page sid string from list_pages or page_summary"
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

      assert call_error("page_summary", %{"verbose" => "yes"}) =~
               "verbose: true or false, got a string"
    end

    test "an explicit connected mount sid reads its whole page" do
      req = session(:request, path: "/users", started_at: @t0)
      query(req)
      mount = session(:live_view, path: "/users", parent: req.sid, started_at: @t0 + 1)
      query(mount)

      assert %{"queries" => %{"count" => 2}, "panel_url" => url} =
               call!("page_summary", %{"sid" => mount.sid})

      assert url == "http://localhost:4000/__pdt/panel?sid=" <> req.sid
      assert %{"sid" => sid, "total" => 2} = call!("page_queries", %{"sid" => mount.sid})
      assert sid == req.sid
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

    test "each query carries its callback, event, caller and noise tag" do
      s = session(:live_view, path: "/q", view: DemoWeb.PageLive)
      callback(s, :handle_event, span: 1, event: "save")

      query(s,
        span: 1,
        stacktrace: [
          "lib/demo/posts.ex:3: Demo.Posts.get/1",
          "lib/demo_web/live/page_live.ex:9: DemoWeb.PageLive.handle_event/3"
        ]
      )

      query(s, span: 1, sql: ~s(SELECT s0."version" FROM "schema_migrations" AS s0))

      assert %{"queries" => [query, noise]} = call!("page_queries", %{"sid" => s.sid})

      assert %{
               "span" => 1,
               "callback" => "handle_event",
               "event" => "save",
               "origin" => "lib/demo/posts.ex:3: Demo.Posts.get/1",
               "caller" => "lib/demo_web/live/page_live.ex:9: DemoWeb.PageLive.handle_event/3",
               "noise" => nil
             } = query

      assert %{"noise" => "check_repo_status"} = noise

      assert %{"queries" => %{"count" => 1, "noise" => %{"count" => 1}}} =
               call!("page_summary", %{"sid" => s.sid})
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

    test "sort slowest puts inferred entries (null duration_us) last" do
      s = session(:live_view, path: "/i")
      callback(s, :mount, span: 1, us: 100)
      query(s, span: 2, us: 30)
      callback(s, :handle_event, event: "go", span: 3, us: 500)

      assert %{
               "callbacks" => [
                 %{"callback" => "handle_event"},
                 %{"callback" => "mount"},
                 %{"callback" => "handle_info", "inferred" => true, "duration_us" => nil}
               ]
             } = call!("page_callbacks", %{"sid" => s.sid, "sort" => "slowest"})
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

    test "each group lists the callbacks it ran in and its callers" do
      s = session(:live_view, path: "/n", view: DemoWeb.PageLive)
      callback(s, :mount, span: 1)
      caller = "lib/demo_web/live/page_live.ex:63: DemoWeb.PageLive.mount/3"

      for _ <- 1..5,
          do:
            query(s,
              span: 1,
              stacktrace: ["lib/demo/policy.ex:7: Demo.Policy.allowed?/2", caller]
            )

      assert %{
               "n_plus_one" => [
                 %{
                   "callbacks" => 1,
                   "ran_in" => [
                     %{
                       "view" => "DemoWeb.PageLive",
                       "callback" => "mount",
                       "event" => nil,
                       "seq" => seq,
                       "count" => 5
                     }
                   ],
                   "callers" => [%{"frame" => ^caller, "count" => 5}]
                 }
               ]
             } = call!("page_n_plus_one", %{"sid" => s.sid})

      assert is_integer(seq)
    end
  end

  describe "page_report" do
    test "returns the Markdown, the sid and a panel_url" do
      s = session(:request, path: "/users")
      query(s)

      assert %{"sid" => sid, "panel_url" => url, "markdown" => md} =
               call!("page_report", %{"sid" => s.sid})

      assert sid == s.sid
      assert url == "http://localhost:4000/__pdt/panel?sid=" <> s.sid
      assert md =~ "# /users"
      assert md =~ "SELECT * FROM users WHERE id = ?"
      assert String.ends_with?(md, "\n---\nsid `#{s.sid}`, panel: #{url}\n")
    end

    test "resolves by path, errors without a page" do
      session(:request, path: "/a")
      assert %{"markdown" => "# /a" <> _} = call!("page_report", %{"path" => "/a"})
      assert call_error("page_report", %{"path" => "/x"}) =~ "No captured page at /x"
    end
  end

  describe "recent_errors" do
    test "errors across pages with total, returned and a panel_url per page" do
      a = failing(:request, "/a", @t0, "boom a")
      b = failing(:live_view, "/b", @t0 + 1, "boom b")

      assert %{"total" => 2, "returned" => 2, "errors" => [first, second]} =
               call!("recent_errors")

      assert %{"message" => "boom b", "path" => "/b", "panel_url" => url_b} = first
      assert %{"message" => "boom a", "panel_url" => url_a} = second
      assert url_b == "http://localhost:4000/__pdt/panel?sid=" <> b.sid
      assert url_a == "http://localhost:4000/__pdt/panel?sid=" <> a.sid
    end

    test "an error of a connected mount links to its request's page" do
      req = session(:request, path: "/a", started_at: @t0)
      mount = failing(:live_view, "/a", @t0 + 1, "in handle_info", parent: req.sid)

      assert %{"errors" => [%{"sid" => sid, "panel_url" => url}]} = call!("recent_errors")
      assert sid == mount.sid
      assert url == "http://localhost:4000/__pdt/panel?sid=" <> req.sid
    end

    test "since takes a sid or a time, limit caps, bad values are tool errors" do
      a = failing(:request, "/a", @t0, "a")
      _b = failing(:request, "/b", @t0 + 5_000_000, "b")
      _c = failing(:request, "/c", @t0 + 9_000_000, "c")

      assert %{"errors" => [%{"message" => "c"}, %{"message" => "b"}]} =
               call!("recent_errors", %{"since" => a.sid})

      iso =
        @t0 |> Kernel.+(5_000_000) |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

      assert %{"errors" => [%{"message" => "c"}]} = call!("recent_errors", %{"since" => iso})

      assert %{"total" => 3, "returned" => 1, "errors" => [%{"message" => "c"}]} =
               call!("recent_errors", %{"limit" => 1})

      assert call_error("recent_errors", %{"limit" => 101}) =~ "limit"
      assert call_error("recent_errors", %{"since" => "not a time"}) =~ "since"
      assert call_error("recent_errors", %{"since" => 5}) =~ "since"
    end

    test "a sid cursor excludes the cursor page's own later crash, keeps newer pages" do
      a = failing(:request, "/a", @t0, "old")
      callback(a, :handle_info, error: "later crash", at: @t0 + 1_000_000)
      _b = failing(:request, "/b", @t0 + 5_000_000, "newer")

      assert %{"errors" => [%{"message" => "newer"}]} =
               call!("recent_errors", %{"since" => a.sid})
    end

    test "items carry page_sid, the request for a connected mount" do
      req = session(:request, path: "/a", started_at: @t0)
      mount = failing(:live_view, "/a", @t0 + 1, "in handle_info", parent: req.sid)

      assert %{"errors" => [%{"sid" => sid, "page_sid" => page}]} = call!("recent_errors")
      assert {sid, page} == {mount.sid, req.sid}
    end

    test "a sid cursor does not move while its tab emits later events" do
      req = failing(:request, "/a", @t0, "old")
      mount = session(:live_view, path: "/a", parent: req.sid, started_at: @t0 + 1_000_000)
      _b = failing(:request, "/b", @t0 + 5_000_000, "newer")
      callback(mount, :handle_info, error: "old tab again", at: @t0 + 9_000_000)

      assert %{"errors" => [%{"message" => "newer"}]} =
               call!("recent_errors", %{"since" => req.sid})
    end

    test "an empty Store gives an empty list" do
      assert %{"total" => 0, "returned" => 0, "errors" => []} = call!("recent_errors")
    end
  end

  describe "compare_pages" do
    @n1 "SELECT * FROM posts WHERE user_id = ?"

    defp slow_page(path, at) do
      s = session(:request, path: path, started_at: at)
      for _ <- 1..5, do: query(s, sql: @n1, span: 2)
      callback(s, :handle_event, error: "boom", us: 10)
      s
    end

    test "after: a sid compares two pages, with both panel urls" do
      before = slow_page("/posts", @t0)
      after_ = session(:request, path: "/posts", started_at: @t0 + 5)
      query(after_, sql: "SELECT * FROM posts", span: 2)

      result = call!("compare_pages", %{"before" => before.sid, "after" => after_.sid})

      assert %{
               "before" => %{"sid" => b, "panel_url" => before_url},
               "after" => %{"sid" => a, "panel_url" => after_url},
               "queries" => %{"delta" => %{"count" => -4}},
               "n_plus_one" => %{"fixed" => [%{"sql" => @n1}], "new" => []},
               "errors" => %{"fixed" => [%{"message" => message}], "new" => []}
             } = result

      refute Map.has_key?(result, "before_panel_url")

      assert {b, a} == {before.sid, after_.sid}
      assert message =~ "boom"
      assert before_url == "http://localhost:4000/__pdt/panel?sid=" <> before.sid
      assert after_url == "http://localhost:4000/__pdt/panel?sid=" <> after_.sid
    end

    test "without after it takes the newest page started after before, at before's path" do
      before = slow_page("/posts", @t0)
      _other = session(:request, path: "/other", started_at: @t0 + 2)
      _older = session(:request, path: "/posts", started_at: @t0 + 3)
      newest = session(:request, path: "/posts", started_at: @t0 + 4)
      _mount = session(:live_view, path: "/posts", parent: newest.sid, started_at: @t0 + 5)

      assert %{"after" => %{"sid" => sid}} = call!("compare_pages", %{"before" => before.sid})
      assert sid == newest.sid
    end

    test "path picks the page after before at another path" do
      before = slow_page("/posts", @t0)
      other = session(:request, path: "/other", started_at: @t0 + 2)

      assert %{"after" => %{"sid" => sid}} =
               call!("compare_pages", %{"before" => before.sid, "path" => "/other"})

      assert sid == other.sid
    end

    test "an explicit path at another page warns that the pages differ" do
      before = slow_page("/posts", @t0)
      _other = session(:request, path: "/other", started_at: @t0 + 2)

      assert %{"warning" => warning} =
               call!("compare_pages", %{"before" => before.sid, "path" => "/other"})

      assert warning =~ "/posts" and warning =~ "/other"
    end

    test "no page after before is a tool error telling to reload" do
      before = slow_page("/posts", @t0)
      _earlier = session(:request, path: "/posts", started_at: @t0 - 5)

      assert call_error("compare_pages", %{"before" => before.sid}) =~ "Reload"
    end

    test "a missing, gone or malformed side is a tool error" do
      before = slow_page("/posts", @t0)

      assert call_error("compare_pages", %{}) =~ "before"
      assert call_error("compare_pages", %{"before" => "gone"}) =~ "before"

      assert call_error("compare_pages", %{"before" => "gone"}) =~
               "Reload the page, then call page_summary for a new sid"

      assert call_error("compare_pages", %{"before" => "bad sid!"}) =~ "before"
      assert call_error("compare_pages", %{"before" => 5}) =~ "before"
      assert call_error("compare_pages", %{"before" => before.sid, "after" => "gone"}) =~ "after"
    end

    test "a wrong argument type says what is expected and how to get it" do
      assert call_error("compare_pages", %{"before" => %{"path" => "/x"}}) ==
               "before: a page sid string (from list_pages or page_summary), got an object. " <>
                 ~s(For the page at "/x", call list_pages with path: "/x" and pass its sid; ) <>
                 ~s(to pick the after page by path, use path: "/x".)

      assert call_error("compare_pages", %{"before" => 5}) =~
               "before: a page sid string (from list_pages or page_summary), got a number"

      assert call_error("page_summary", %{"path" => ["/x"]}) ==
               ~s(path: an exact request path string, such as "/posts", got an array.)

      assert call_error("list_pages", %{"limit" => 0}) == "limit: an integer from 1 to 50, got 0."

      assert call_error("page_summary", %{"bogus" => 1}) =~
               "Unknown argument(s): \"bogus\". Accepted: path, sid, verbose."
    end

    test "an after older than before is a tool error" do
      before = slow_page("/posts", @t0)
      older = session(:request, path: "/posts", started_at: @t0 - 5)

      msg = call_error("compare_pages", %{"before" => before.sid, "after" => older.sid})
      assert msg =~ "older" and msg =~ "swap"
    end

    test "a before without a path never matches every page" do
      before = session(:request, path: nil, started_at: @t0)
      _other = session(:request, path: "/other", started_at: @t0 + 1)

      assert call_error("compare_pages", %{"before" => before.sid}) =~ "Reload"
    end

    test "a connected mount as before compares its request" do
      req = slow_page("/posts", @t0)
      mount = session(:live_view, path: "/posts", parent: req.sid, started_at: @t0 + 1)
      after_ = session(:request, path: "/posts", started_at: @t0 + 5)

      assert %{"before" => %{"sid" => sid, "panel_url" => url}} =
               call!("compare_pages", %{"before" => mount.sid, "after" => after_.sid})

      assert sid == req.sid
      assert url =~ req.sid
    end

    test "after and path together is a tool error" do
      before = slow_page("/posts", @t0)

      msg =
        call_error("compare_pages", %{
          "before" => before.sid,
          "after" => before.sid,
          "path" => "/posts"
        })

      assert msg =~ "after" and msg =~ "path"
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
