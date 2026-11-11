defmodule PhoenixDevToolbar.Plugins.EctoTest do
  # Reads `config :phoenix_dev_toolbar, repos:` and attaches global handlers.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import PhoenixDevToolbar.EnvHelpers
  import PhoenixDevToolbar.PageHelpers, only: [ms: 1, with_plugins: 2]
  import PhoenixDevToolbar.ProcessHelpers

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Plugins.Ecto, as: EctoPlugin
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @event [:demo, :repo, :query]

  setup do
    with_plugins([EctoPlugin], repos: [DemoWeb.FakeRepo])

    %Session{sid: sid} = Store.new_session(Session.new(:request))
    %{sid: sid}
  end

  defp query_metadata(overrides) do
    Map.merge(
      %{
        type: :ecto_sql_query,
        repo: DemoWeb.FakeRepo,
        query: ~s|SELECT u0."id" FROM "users" AS u0 WHERE (u0."email" = $1)|,
        # The driver gets `params` (dumped); `cast_params` (pre-dump) is shown.
        params: ["dumped:ada@example.com"],
        cast_params: ["ada@example.com"],
        source: "users",
        result: {:ok, %{num_rows: 1}},
        stacktrace: [
          {Ecto.Repo.Queryable, :all, 3, [file: ~c"lib/ecto/repo/queryable.ex", line: 22]},
          {DemoWeb.FakeRepo, :all, 2, [file: ~c"lib/demo/repo.ex", line: 2]},
          {DemoWeb.Users, :by_email, 1, [file: ~c"lib/demo/users.ex", line: 9]}
        ],
        options: []
      },
      overrides
    )
  end

  defp run_query(sid, metadata, fun \\ &apply/2) do
    measurements = %{query_time: ms(3), queue_time: ms(1), decode_time: ms(1), total_time: ms(5)}
    emit = fn -> :telemetry.execute(@event, measurements, metadata) end

    tracked(sid, fn -> fun.(emit, []) end)
  end

  defp events(opts) do
    {:ok, config} = EctoPlugin.init(opts)
    EctoPlugin.telemetry_events(config)
  end

  test "attaches to the query event of each configured repo" do
    assert events([]) == [@event]
  end

  test "the plugin's repos option wins over the app env, and is validated" do
    put_app_env(:repos, [DemoWeb.HelloPlug])

    assert events(repos: [DemoWeb.FakeRepo]) == [@event]
    assert {:error, message} = EctoPlugin.init(repos: DemoWeb.FakeRepo)
    assert message =~ "list of modules"
  end

  describe "without repos configured" do
    setup do
      delete_app_env(:repos)
    end

    test "falls back to the :ecto_repos of the loaded applications" do
      put_app_env(:ecto_repos, [DemoWeb.FakeRepo])

      assert events([]) == [@event]
    end

    test "explicit config wins over the fallback" do
      put_app_env(:ecto_repos, [DemoWeb.HelloPlug])

      assert events(repos: [DemoWeb.FakeRepo]) == [@event]
      put_app_env(:repos, [DemoWeb.FakeRepo])
      assert events([]) == [@event]
    end

    test "an explicit empty list opts out, silently" do
      put_app_env(:ecto_repos, [DemoWeb.FakeRepo])

      log = capture_log(fn -> assert events(repos: []) == [] end)
      assert log == ""
    end

    test "finding nothing logs one warning naming the config line" do
      log = capture_log(fn -> assert events([]) == [] end)

      assert log =~ "no Ecto repos found"
      assert log =~ "config :phoenix_dev_toolbar, repos: [MyApp.Repo]"
      assert length(String.split(log, "no Ecto repos found")) == 2
    end
  end

  test "n_plus_one: defaults to 5, takes an integer >= 2 or false, and is validated" do
    assert {:ok, %{n_plus_one: 5}} = EctoPlugin.init([])
    assert {:ok, %{n_plus_one: 3}} = EctoPlugin.init(n_plus_one: 3)
    assert {:ok, %{n_plus_one: false}} = EctoPlugin.init(n_plus_one: false)

    for bad <- [1, true, "5", nil] do
      assert {:error, "n_plus_one must be" <> _} = EctoPlugin.init(n_plus_one: bad)
    end
  end

  test "caller_modules: defaults to the Web patterns, takes regexes or prefixes, and is validated" do
    assert {:ok, %{caller_modules: [%Regex{}, %Regex{}]}} = EctoPlugin.init([])

    assert {:ok, %{caller_modules: ["Demo.Policy", %Regex{}]}} =
             EctoPlugin.init(caller_modules: ["Demo.Policy", ~r/Live\z/])

    for bad <- [:web, [:web], "Demo"] do
      assert {:error, "caller_modules must be" <> _} = EctoPlugin.init(caller_modules: bad)
    end
  end

  test "framework queries are left out of the badge counts, named in its title" do
    summary =
      [
        Event.new(
          :ecto,
          :query,
          %{sql: ~s(SELECT s0."version" FROM "schema_migrations" AS s0), stacktrace: []},
          duration: 900
        ),
        Event.new(:ecto, :query, %{sql: "SELECT 1", stacktrace: [], result: {:ok, 1}},
          duration: 10
        )
      ]
      |> Enum.reduce(EctoPlugin.summary_init(%{n_plus_one: 5}), &EctoPlugin.summary_add(&2, &1))

    assert [%{id: "ecto-queries", text: "1 query · " <> _, title: title}] =
             EctoPlugin.badges(summary)

    assert title =~ "1 framework query"
  end

  test "keeps the raw params of a SELECT for EXPLAIN, not of a write", %{sid: sid} do
    run_query(sid, query_metadata(%{}))
    run_query(sid, query_metadata(%{query: "UPDATE users SET name = $1", params: ["ada"]}))

    assert [
             %Event{data: %{explain: {:ok, ["dumped:ada@example.com"]}}},
             %Event{data: %{explain: {:no, :not_select}}}
           ] =
             Store.events(sid)
  end

  test "records SQL, timings, rows and the caller's origin", %{sid: sid} do
    run_query(sid, query_metadata(%{}))

    assert [%Event{plugin: :ecto, kind: :query, duration: 5000, data: data}] = Store.events(sid)

    assert %{
             repo: DemoWeb.FakeRepo,
             source: "users",
             params: ~s(["ada@example.com"]),
             result: {:ok, 1},
             times: %{query_time: 3000, queue_time: 1000, decode_time: 1000, total_time: 5000},
             stacktrace: ["lib/demo/users.ex:9: DemoWeb.Users.by_email/1"],
             caller?: false
           } = data

    assert data.sql =~ ~s(FROM "users")
  end

  test "marks queries run by Task.async children of the page", %{sid: sid} do
    run_query(sid, query_metadata(%{}), fn emit, [] -> emit |> Task.async() |> Task.await() end)

    assert [%Event{data: %{caller?: true}}] = Store.events(sid)
  end

  test "records failed queries with their error message", %{sid: sid} do
    error = %ArgumentError{message: "relation \"users\" does not exist"}

    run_query(sid, query_metadata(%{result: {:error, error}}))

    assert [%Event{data: %{result: {:error, "relation \"users\" does not exist"}}}] =
             Store.events(sid)
  end

  test "redacts sensitive keyword params", %{sid: sid} do
    run_query(sid, query_metadata(%{cast_params: [password: "hunter2"]}))

    assert [%Event{data: %{params: ~s([password: "[REDACTED]"])}}] = Store.events(sid)
  end

  test "redacts a scalar-only struct param by its field names", %{sid: sid} do
    creds = %PhoenixDevToolbar.TestCreds{secret_key: "sk_live", user: "ada"}

    run_query(sid, query_metadata(%{cast_params: [creds]}))

    assert [%Event{data: %{params: stored}}] = Store.events(sid)
    assert stored =~ "[REDACTED]"
    refute stored =~ "sk_live"
  end

  test "stores huge params within a byte cap and still redacts", %{sid: sid} do
    huge = for n <- 1..100, do: String.duplicate("x", 5_000) <> to_string(n)
    wide = for i <- 1..50, do: for(_ <- 1..50, do: for(_ <- 1..50, do: %{id: i}))
    params = [{:password, "hunter2"}, {:blob, huge}, {:json, wide}]

    run_query(sid, query_metadata(%{cast_params: params}))

    assert [%Event{data: %{params: stored}}] = Store.events(sid)
    assert byte_size(stored) <= 2048 + byte_size(" [truncated]")
    assert stored =~ "[REDACTED]"
    refute stored =~ "hunter2"
  end

  test "skips, with a warning, configured modules that are not repos" do
    put_app_env(:repos, [DemoWeb.HelloPlug])

    log = capture_log(fn -> assert events([]) == [] end)

    assert log =~ "ignoring repo DemoWeb.HelloPlug"
  end
end
