defmodule PhoenixDevToolbar.ReportFixtures do
  @moduledoc false
  # Sessions and events in the Store, shaped as the collectors store them.
  # Callers reset the Store themselves.

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @t0 1_800_000_000_000_000

  def session(kind, attrs \\ []) do
    {started_at, attrs} = Keyword.pop(attrs, :started_at, @t0)
    Store.new_session(%{Session.new(kind, attrs) | started_at: started_at})
  end

  def insert(%Session{sid: sid}, plugin, kind, data, opts \\ []) do
    event = Event.new(plugin, kind, data, at: Keyword.get(opts, :at, @t0))
    event = %{event | duration: Keyword.get(opts, :us), span: Keyword.get(opts, :span, 1)}
    :ok = Store.insert(sid, event)
  end

  def query(session, opts \\ []) do
    data = %{
      repo: DemoWeb.SQLiteRepo,
      sql: Keyword.get(opts, :sql, "SELECT * FROM users WHERE id = ?"),
      params: "[1]",
      source: "users",
      result: Keyword.get(opts, :result, {:ok, 1}),
      times: %{query_time: 90, queue_time: 10},
      stacktrace: Keyword.get(opts, :stacktrace, ["lib/app.ex:10: App.list/0"]),
      caller?: Keyword.get(opts, :caller?, false),
      initial_call: Keyword.get(opts, :initial_call),
      explain: {:ok, ["raw-secret-param"]}
    }

    insert(session, :ecto, :query, data, Keyword.put_new(opts, :us, 100))
  end

  def callback(session, callback, opts \\ []) do
    data = %{
      callback: callback,
      view: DemoWeb.PageLive,
      component: nil,
      cid: nil,
      id: nil,
      count: nil,
      connected?: true,
      nested?: false,
      event: Keyword.get(opts, :event),
      params: nil,
      changes: %{keys: [:count], values: %{count: "1"}, omitted: 0},
      pushed: [],
      error: Keyword.get(opts, :error)
    }

    data =
      case Keyword.fetch(opts, :stack_args) do
        {:ok, args} ->
          Map.merge(data, %{stack_args: args, stacktrace: Keyword.fetch!(opts, :stacktrace)})

        :error ->
          data
      end

    insert(session, :live_view, :callback, data, opts)
  end

  def request(session, opts \\ []) do
    route = %{
      method: "GET",
      path: session.path,
      route: "/users/:id",
      handler: "DemoWeb.UserController :show",
      status: 200,
      path_params: %{"id" => "1"}
    }

    insert(session, :request, :dispatch, route, us: 800)

    insert(
      session,
      :request,
      :response,
      %{method: "GET", path: session.path, status: 200, content_type: "text/html"},
      us: Keyword.get(opts, :us, 1000)
    )
  end

  @doc """
  A session of `kind` with one failing `:handle_info` callback. The error lands
  at `:at` (default `started_at`); other options go to the session.
  """
  def failing(kind, path, started_at, message, opts \\ []) do
    {at, attrs} = Keyword.pop(opts, :at, started_at)
    s = session(kind, Keyword.merge([path: path, started_at: started_at], attrs))
    callback(s, :handle_info, error: message, at: at)
    s
  end
end
