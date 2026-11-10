defmodule PhoenixDevToolbar.ReportTest do
  # The read API over the Store (ADR 13). The Store owns named ETS tables
  # shared by the whole node.
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.ReportFixtures

  alias PhoenixDevToolbar.Report
  alias PhoenixDevToolbar.Store

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
  end

  @t0 1_800_000_000_000_000

  describe "sessions/1 and latest/1" do
    test "lists sessions newest first, with plain fields" do
      old = session(:request, path: "/a", started_at: @t0)
      new = session(:live_view, path: "/b", view: DemoWeb.PageLive, started_at: @t0 + 5)

      assert [%{sid: new_sid} = latest, %{sid: old_sid}] = Report.sessions()
      assert {new_sid, old_sid} == {new.sid, old.sid}

      assert %{
               kind: :live_view,
               path: "/b",
               view: DemoWeb.PageLive,
               parent: nil,
               started_at: %DateTime{},
               events: 0,
               dropped: 0,
               trimmed: 0
             } = latest
    end

    test "filters by path, regex, view, kind and limit" do
      session(:request, path: "/users", started_at: @t0)
      session(:live_view, path: "/users/1", view: DemoWeb.PageLive, started_at: @t0 + 1)
      session(:live_view, path: "/posts", view: DemoWeb.NestedLive, started_at: @t0 + 2)

      assert [%{path: "/users"}] = Report.sessions(path: "/users")
      assert [%{path: "/users/1"}, %{path: "/users"}] = Report.sessions(path: ~r{^/users})
      assert [%{path: "/posts"}] = Report.sessions(view: DemoWeb.NestedLive)
      assert [%{kind: :request}] = Report.sessions(kind: :request)
      assert [%{path: "/posts"}] = Report.sessions(limit: 1)
    end

    test "latest/1 is the newest match, or nil" do
      session(:request, path: "/users", started_at: @t0)
      session(:request, path: "/users", started_at: @t0 + 1)

      assert %{started_at: at} = Report.latest(path: "/users")
      assert DateTime.to_unix(at, :microsecond) == @t0 + 1
      assert Report.latest(path: "/nowhere") == nil
    end
  end

  describe "targets" do
    test "a request includes the LiveView that joined from it, not later navigation" do
      root = session(:request, path: "/users")
      mount = session(:live_view, path: "/users", parent: root.sid, started_at: @t0 + 1)
      nav = session(:live_view, path: "/posts", parent: mount.sid, started_at: @t0 + 2)
      query(root, sql: "SELECT 1")
      query(mount, sql: "SELECT 2")
      query(nav, sql: "SELECT 3")

      assert ["SELECT 1", "SELECT 2"] == root.sid |> Report.queries() |> Enum.map(& &1.sql)
      assert ["SELECT 1"] == root.sid |> Report.queries(children: false) |> Enum.map(& &1.sql)
      assert ["SELECT 2"] == mount.sid |> Report.queries() |> Enum.map(& &1.sql)
      assert ["SELECT 3"] == [nav.sid] |> Report.queries() |> Enum.map(& &1.sql)

      assert ["SELECT 1", "SELECT 2"] ==
               Report.latest(kind: :request) |> Report.queries() |> Enum.map(& &1.sql)
    end

    test "an unknown sid reads as empty" do
      assert Report.queries("missing") == []
      assert Report.summary("missing") == nil
    end
  end

  describe "queries/2" do
    test "returns plain query maps in order, without raw EXPLAIN params" do
      s = session(:request, path: "/users")
      query(s, at: @t0 + 1)
      query(s, sql: "INSERT", result: {:error, "constraint failed"}, at: @t0 + 2)

      assert [ok, failed] = Report.queries(s.sid)

      assert %{
               sid: sid,
               seq: seq,
               span: 1,
               at: %DateTime{},
               duration_us: 100,
               repo: "DemoWeb.SQLiteRepo",
               sql: "SELECT * FROM users WHERE id = ?",
               params: "[1]",
               source: "users",
               rows: 1,
               error: nil,
               times: %{query_time: 90, queue_time: 10},
               origin: "lib/app.ex:10: App.list/0",
               stacktrace: ["lib/app.ex:10: App.list/0"],
               n_plus_one?: false
             } = ok

      assert sid == s.sid and is_integer(seq)
      assert %{rows: nil, error: "constraint failed"} = failed
      refute inspect(Report.queries(s.sid)) =~ "raw-secret-param"
    end
  end

  describe "n_plus_one/2" do
    test "groups repeated SQL from one origin in one callback span" do
      s = session(:live_view, path: "/users")
      for _ <- 1..5, do: query(s, sql: "SELECT * FROM posts WHERE user_id = ?", span: 2)
      query(s, sql: "SELECT 1", span: 2)

      assert [group] = Report.n_plus_one(s.sid, threshold: 5)

      assert %{
               sql: "SELECT * FROM posts WHERE user_id = ?",
               origin: "lib/app.ex:10: App.list/0",
               count: 5,
               callbacks: 1,
               sids: [_]
             } = group

      assert Report.n_plus_one(s.sid, threshold: 6) == []
      assert Report.n_plus_one(s.sid, threshold: false) == []

      assert [false, false, false, false, true, false] ==
               s.sid |> Report.queries(threshold: 5) |> Enum.map(& &1.n_plus_one?)
    end
  end

  describe "callbacks/2" do
    test "counts each callback's queries and DB time by span" do
      s = session(:live_view, path: "/users")
      query(s, span: 1, us: 40)
      callback(s, :mount, span: 1, us: 500)
      query(s, span: 2, us: 30)
      query(s, span: 2, us: 20)
      callback(s, :handle_event, span: 2, us: 300, event: "inc")
      callback(s, :handle_params, span: 3, us: 10)

      assert [mount, event, params] = Report.callbacks(s.sid)

      assert %{
               callback: :mount,
               view: DemoWeb.PageLive,
               component: nil,
               duration_us: 500,
               queries: 1,
               query_us: 40,
               changes: %{keys: [:count]},
               error: nil
             } = mount

      assert %{callback: :handle_event, event: "inc", queries: 2, query_us: 50} = event
      assert %{queries: 0, query_us: 0} = params
    end
  end

  describe "errors/2" do
    test "collects request exceptions, failed callbacks and renders, failed queries" do
      s = session(:live_view, path: "/users")

      insert(s, :request, :exception, %{
        path: "/users",
        error: "** (RuntimeError) boom",
        stacktrace: ["lib/a.ex:1"]
      })

      callback(s, :handle_event, error: "** (ArgumentError) bad", event: "x")
      insert(s, :live_view, :render, %{view: DemoWeb.PageLive, error: "** (KeyError) k"})
      query(s, result: {:error, "no such table"})

      assert [
               %{source: :request, message: "** (RuntimeError) boom", stacktrace: ["lib/a.ex:1"]},
               %{source: :live_view, message: "** (ArgumentError) bad"},
               %{source: :live_view, message: "** (KeyError) k"},
               %{source: :ecto, message: "no such table"}
             ] = Report.errors(s.sid)
    end
  end

  describe "summary/2" do
    test "one compact map per page" do
      root = session(:request, path: "/users")
      mount = session(:live_view, path: "/users", parent: root.sid, started_at: @t0 + 1)
      request(root, us: 1200)
      for us <- 1..7, do: query(mount, us: us * 10, sql: "SELECT #{us}", span: us)
      query(mount, result: {:error, "boom"}, us: 1, span: 9)
      callback(mount, :mount, span: 1, us: 900)
      insert(mount, :live_view, :render, %{view: DemoWeb.PageLive, error: nil}, us: 50)
      insert(mount, :live_view, :render, %{view: DemoWeb.PageLive, error: nil}, us: 25)

      summary = Report.summary(root.sid)

      assert summary.sids == [root.sid, mount.sid]
      assert %{sid: sid, kind: :request, path: "/users"} = summary.session
      assert sid == root.sid

      assert %{
               method: "GET",
               path: "/users",
               route: "/users/:id",
               handler: "DemoWeb.UserController :show",
               status: 200,
               duration_us: 1200
             } = summary.request

      assert %{count: 8, failed: 1, total_us: 281, slowest: slowest} = summary.queries
      assert Enum.map(slowest, & &1.duration_us) == [70, 60, 50, 40, 30]
      assert %{count: 1, total_us: 900, slowest: [%{callback: :mount}]} = summary.callbacks
      assert summary.renders == %{count: 2, total_us: 75}
      assert [%{source: :ecto}] = summary.errors
      assert summary.n_plus_one == []
      assert %{dropped: 0, trimmed: 0} = summary
    end

    test "accepts a session map" do
      s = session(:request, path: "/users")
      assert %{sids: [sid], request: nil} = s.sid |> Report.summary()
      assert sid == s.sid
      assert %{sids: [^sid]} = Report.summary(Report.latest())
    end
  end

  test "reads nothing while the toolbar is disabled" do
    s = session(:request, path: "/users")
    query(s)

    Application.put_env(:phoenix_dev_toolbar, :enabled, false)
    on_exit(fn -> Application.put_env(:phoenix_dev_toolbar, :enabled, true) end)

    assert Report.sessions() == []
    assert Report.latest() == nil
    assert Report.queries(s.sid) == []
    assert Report.summary(s.sid) == nil
  end
end
