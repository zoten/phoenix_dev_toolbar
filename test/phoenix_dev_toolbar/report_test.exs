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
    test "since: a sid or a DateTime keeps only sessions started after it" do
      a = session(:request, path: "/a", started_at: @t0)
      b = session(:request, path: "/b", started_at: @t0 + 5)
      c = session(:request, path: "/c", started_at: @t0 + 9)

      assert [c.sid, b.sid] == Enum.map(Report.sessions(since: a.sid), & &1.sid)
      assert [c.sid] == Enum.map(Report.sessions(since: b.sid), & &1.sid)
      assert [] == Report.sessions(since: c.sid)

      cursor = DateTime.from_unix!(@t0 + 5, :microsecond)
      assert [c.sid] == Enum.map(Report.sessions(since: cursor), & &1.sid)
      assert [c.sid] == Enum.map(Report.sessions(since: cursor, path: "/c"), & &1.sid)
    end

    test "since: an unknown sid or an unusable value gives no sessions, never a raise" do
      session(:request, path: "/a", started_at: @t0)

      assert [] == Report.sessions(since: "gone")
      assert [] == Report.sessions(since: 42)
      assert [%{path: "/a"}] = Report.sessions(since: nil)
    end

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

  describe "query origin" do
    test "falls back from the first frame to the task function to the owning callback" do
      s = session(:live_view, view: DemoWeb.PageLive)
      callback(s, :handle_event, event: "save", span: 3)
      query(s, sql: "frame", span: 3, caller?: true, initial_call: "App.run/0")
      query(s, sql: "initial", span: 3, caller?: true, stacktrace: [], initial_call: "App.run/0")
      query(s, sql: "owner", span: 3, caller?: true, stacktrace: [])
      query(s, sql: "view", span: 9, caller?: true, stacktrace: [])
      query(s, sql: "inline", span: 9, stacktrace: [])

      origins = Map.new(Report.queries(s.sid), &{&1.sql, &1.origin})

      assert origins["frame"] == "lib/app.ex:10: App.list/0"
      assert origins["initial"] == "App.run/0"
      assert origins["owner"] == ~s(task in DemoWeb.PageLive.handle_event "save")
      assert origins["view"] == "task in DemoWeb.PageLive"
      assert origins["inline"] == nil
    end

    test "an orphan task query has the same origin in queries, briefs and unattributed" do
      request = session(:request, path: "/demo")
      live = session(:live_view, parent: request.sid, path: "/demo", view: DemoWeb.PageLive)
      callback(live, :handle_event, event: "load", span: 1)
      query(live, span: 2, caller?: true, stacktrace: [])

      [full] = Report.queries(request.sid)
      summary = Report.summary(request.sid)

      assert full.origin == "task in DemoWeb.PageLive"
      assert [%{origin: "task in DemoWeb.PageLive"}] = summary.queries.slowest
      assert [%{origin: "task in DemoWeb.PageLive", count: 1}] = summary.unattributed.origins

      assert [%{inferred: true, callback: :async, origin: "task in DemoWeb.PageLive"}] =
               Enum.filter(Report.callbacks(request.sid), & &1.inferred)
    end

    test "a failed query in a task has the query origin in errors" do
      s = session(:live_view, view: DemoWeb.PageLive)
      callback(s, :handle_event, event: "save", span: 3)
      query(s, span: 3, caller?: true, stacktrace: [], result: {:error, "no such table"})

      assert [%{source: :ecto, origin: origin}] = Report.errors(s.sid)
      assert origin == ~s(task in DemoWeb.PageLive.handle_event "save")
      assert [%{origin: ^origin}] = Report.queries(s.sid)
    end

    test "an error brief origin is the first host frame the plugin stored" do
      s = session(:live_view, path: "/users")

      insert(
        s,
        :live_view,
        :callback,
        %{
          view: DemoWeb.PageLive,
          callback: :mount,
          error: "** (RuntimeError) x",
          origin: "lib/h.ex:1: H.f/0",
          stacktrace: ["(phoenix 1.8) a.ex:1: A.b/0", "lib/h.ex:1: H.f/0"]
        }
      )

      assert [%{origin: "lib/h.ex:1: H.f/0"}] = Report.summary(s.sid).errors
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

    test "infers handle_info entries from queries no callback owns" do
      s = session(:live_view, path: "/users", view: DemoWeb.PageLive)
      callback(s, :mount, span: 1, us: 500)
      query(s, span: 2, us: 40, at: @t0 + 1_000)
      query(s, span: 2, us: 60, at: @t0 + 2_000)
      query(s, span: 2, us: 10, at: @t0 + 500_000, stacktrace: [])
      callback(s, :handle_event, span: 3, us: 300, event: "inc")
      insert(s, :live_view, :render, %{view: DemoWeb.PageLive, error: nil}, span: 4, us: 5)
      query(s, span: 4, us: 7)

      assert [mount, first, second, event] = Report.callbacks(s.sid)
      assert %{callback: :mount, inferred: false} = mount
      assert %{callback: :handle_event, inferred: false} = event

      assert %{
               callback: :handle_info,
               inferred: true,
               view: DemoWeb.PageLive,
               component: nil,
               event: nil,
               params: nil,
               changes: nil,
               error: nil,
               duration_us: nil,
               queries: 2,
               query_us: 100,
               span: 2
             } = first

      assert %{inferred: true, queries: 1, query_us: 10, span: 2} = second
      assert first.seq < second.seq
      assert first.at == DateTime.from_unix!(@t0 + 1_000, :microsecond)
    end

    test "splits inferred entries by source: LiveView process or task" do
      s = session(:live_view, path: "/users", view: DemoWeb.PageLive)
      query(s, span: 2, at: @t0 + 1_000, stacktrace: [])
      query(s, span: 2, at: @t0 + 2_000, caller?: true, stacktrace: [], initial_call: "App.run/0")

      assert [first, second] = Report.callbacks(s.sid)
      assert %{callback: :handle_info, inferred: true, queries: 1, origin: nil} = first
      assert %{callback: :async, inferred: true, queries: 1, origin: "App.run/0"} = second
    end

    test "request sessions have no inferred callbacks" do
      s = session(:request, path: "/users")
      query(s, span: 2)
      assert Report.callbacks(s.sid) == []
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

    test "unattributed groups orphan live view queries by origin, top 5" do
      s = session(:live_view, path: "/users")
      callback(s, :mount, span: 1, us: 500)
      query(s, span: 1, us: 999)
      for n <- 1..6, do: query(s, span: 2, us: n * 10, stacktrace: ["lib/o#{n}.ex:1: O.f/0"])
      query(s, span: 2, us: 1, stacktrace: ["lib/o6.ex:1: O.f/0"])
      query(s, span: 2, us: 2, stacktrace: [])

      summary = Report.summary(s.sid)
      assert %{count: 8, total_us: 213, origins: origins} = summary.unattributed
      assert length(origins) == 5

      assert [%{origin: "lib/o6.ex:1: O.f/0", count: 2, total_us: 61}, %{total_us: 50} | _] =
               origins

      assert %{count: 1, total_us: 500} = summary.callbacks
      assert Map.keys(hd(origins)) |> Enum.sort() == ~w(count origin total_us)a
      assert %{unattributed: %{count: 8}} = Report.summary(s.sid, verbose: true)
    end

    test "request queries are never unattributed" do
      s = session(:request, path: "/users")
      query(s, span: 2)
      assert %{count: 0, total_us: 0, origins: []} = Report.summary(s.sid).unattributed
    end

    test "items are compact by default, full with verbose: true" do
      root = session(:request, path: "/users")
      mount = session(:live_view, path: "/users", parent: root.sid, started_at: @t0 + 1)
      query(mount, us: 70, span: 1)
      query(mount, result: {:error, "boom"}, us: 1, span: 2)
      callback(mount, :mount, span: 1, us: 900)

      assert %{
               queries: %{slowest: [brief | _]},
               callbacks: %{slowest: [cb_brief]},
               errors: [err_brief]
             } = Report.summary(root.sid)

      assert Map.keys(brief) |> Enum.sort() ==
               ~w(duration_us error n_plus_one? origin rows seq sid source)a

      assert brief.origin == "lib/app.ex:10: App.list/0"

      assert Map.keys(cb_brief) |> Enum.sort() ==
               ~w(callback component duration_us error event inferred origin queries query_us seq sid view)a

      assert Map.keys(err_brief) |> Enum.sort() == ~w(message origin seq sid source)a
      assert err_brief.message == "boom"

      assert %{
               queries: %{slowest: [%{sql: _, params: _, stacktrace: _, times: _} | _]},
               callbacks: %{slowest: [%{changes: _, params: _}]},
               errors: [%{stacktrace: _, at: _}]
             } = Report.summary(root.sid, verbose: true)
    end

    test "accepts a session map" do
      s = session(:request, path: "/users")
      assert %{sids: [sid], request: nil} = s.sid |> Report.summary()
      assert sid == s.sid
      assert %{sids: [^sid]} = Report.summary(Report.latest())
    end
  end

  describe "compare/3" do
    @n1 "SELECT * FROM posts WHERE user_id = ?"

    defp page(path, started_at, fun) do
      s = session(:request, path: path, started_at: started_at)
      fun.(s)
      s
    end

    test "an N+1 fixed, its deltas, and an error fixed" do
      before =
        page("/posts", @t0, fn s ->
          for _ <- 1..5, do: query(s, sql: @n1, span: 2, us: 100)
          query(s, sql: "SELECT 1", span: 3, us: 50)
          callback(s, :handle_event, error: "** (RuntimeError) boom", us: 10)
        end)

      after_ =
        page("/posts", @t0 + 5, fn s ->
          query(s, sql: "SELECT * FROM posts", span: 2, us: 40)
          query(s, sql: "SELECT 1", span: 3, us: 50)
        end)

      assert %{
               before: %{sid: b, path: "/posts", started_at: %DateTime{}},
               after: %{sid: a, path: "/posts"},
               queries: %{
                 before: %{count: 6, total_us: 550},
                 after: %{count: 2, total_us: 90},
                 delta: %{count: -4, total_us: -460}
               },
               callbacks: %{delta: %{count: -1}},
               renders: %{delta: %{count: 0, total_us: 0}},
               unattributed: %{before: %{count: _}, after: %{count: _}, delta: %{count: _}},
               n_plus_one: %{fixed: [%{sql: @n1, origin: origin}], new: [], still: 0},
               errors: %{fixed: [%{source: :live_view, message: message}], new: []}
             } = Report.compare(before.sid, after_.sid, threshold: 5)

      assert {b, a} == {before.sid, after_.sid}
      assert origin == "lib/app.ex:10: App.list/0"
      assert message =~ "boom"
    end

    test "an N+1 and an error that appear are new, one that stays is still" do
      before =
        page("/posts", @t0, fn s ->
          for _ <- 1..5, do: query(s, sql: @n1, span: 2)
          callback(s, :handle_event, error: "same", us: 10)
        end)

      after_ =
        page("/posts", @t0 + 5, fn s ->
          for _ <- 1..5, do: query(s, sql: @n1, span: 2)
          for _ <- 1..5, do: query(s, sql: "SELECT * FROM tags WHERE id = ?", span: 3)
          callback(s, :handle_event, error: "same", us: 10)
          callback(s, :handle_event, error: "fresh", us: 10)
        end)

      assert %{
               n_plus_one: %{
                 fixed: [],
                 new: [%{sql: "SELECT * FROM tags WHERE id = ?"}],
                 still: 1
               },
               errors: %{fixed: [], new: [%{message: "fresh"}]}
             } = Report.compare(before.sid, after_.sid, threshold: 5)
    end

    test "an N+1 whose call site moved to another line is still, not fixed and new" do
      before =
        page("/posts", @t0, fn s ->
          for _ <- 1..5,
              do: query(s, sql: @n1, span: 2, stacktrace: ["lib/app.ex:10: App.list/0"])
        end)

      after_ =
        page("/posts", @t0 + 5, fn s ->
          for _ <- 1..5,
              do: query(s, sql: @n1, span: 2, stacktrace: ["lib/app.ex:14: App.list/0"])
        end)

      assert %{n_plus_one: %{fixed: [], new: [], still: 1}} =
               Report.compare(before.sid, after_.sid, threshold: 5)
    end

    test "the same error with another pid or id is still, and repeats are counted once" do
      before =
        page("/posts", @t0, fn s ->
          callback(s, :handle_event, error: "** (RuntimeError) boom #PID<0.123.0> id 41", us: 1)
          callback(s, :handle_event, error: "** (RuntimeError) boom #PID<0.124.0> id 42", us: 1)
        end)

      after_ =
        page("/posts", @t0 + 5, fn s ->
          callback(s, :handle_event, error: "** (RuntimeError) boom #PID<0.999.0> id 7", us: 1)
        end)

      assert %{errors: %{fixed: [], new: [], still: 1}} =
               Report.compare(before.sid, after_.sid)

      gone = page("/posts", @t0 + 9, fn _s -> :ok end)

      assert %{errors: %{fixed: [%{count: 2}], fixed_total: 1, new: [], new_total: 0}} =
               Report.compare(before.sid, gone.sid)
    end

    test "fixed and new lists are capped, their totals are not" do
      before =
        page("/posts", @t0, fn s ->
          for c <- ?a..?y, do: callback(s, :handle_event, error: "err " <> <<c>>, us: 1)
        end)

      after_ = page("/posts", @t0 + 5, fn _s -> :ok end)

      assert %{errors: %{fixed: fixed, fixed_total: 25, new: [], new_total: 0}} =
               Report.compare(before.sid, after_.sid)

      assert length(fixed) == 20
    end

    test "a connected mount as before reads its request, both sides count their mounts" do
      req_a = page("/posts", @t0, fn s -> query(s, span: 2, us: 100) end)

      mount_a =
        session(:live_view, path: "/posts", parent: req_a.sid, started_at: @t0 + 1)

      query(mount_a, span: 3, us: 100)

      req_b = page("/posts", @t0 + 5, fn s -> query(s, span: 2, us: 10) end)

      mount_b =
        session(:live_view, path: "/posts", parent: req_b.sid, started_at: @t0 + 6)

      query(mount_b, span: 3, us: 10)

      assert %{
               before: %{sid: b, kind: :request, sids: [_, _]},
               after: %{sid: a, kind: :request, sids: [_, _]},
               queries: %{before: %{count: 2}, after: %{count: 2}, delta: %{total_us: -180}}
             } = result = Report.compare(mount_a.sid, mount_b.sid)

      assert {b, a} == {req_a.sid, req_b.sid}
      refute Map.has_key?(result, :warning)
    end

    test "sides of another kind or session count carry a warning" do
      req = page("/posts", @t0, fn _s -> :ok end)
      mount = session(:live_view, path: "/posts", parent: req.sid, started_at: @t0 + 1)
      _ = mount
      nav = session(:live_view, path: "/posts", parent: "gone-lv", started_at: @t0 + 5)

      assert %{after: %{kind: :live_view, sids: [_]}, warning: warning} =
               Report.compare(req.sid, nav.sid)

      assert warning =~ "request" and warning =~ "live_view"
    end

    test "takes session maps, and is nil when either side is gone" do
      a = session(:request, path: "/a", started_at: @t0)
      b = session(:request, path: "/a", started_at: @t0 + 1)

      assert %{before: %{sid: sid}} = Report.compare(Report.latest(path: "/a"), a.sid)
      assert sid == b.sid
      assert Report.compare(a.sid, "gone") == nil
      assert Report.compare("gone", a.sid) == nil
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
