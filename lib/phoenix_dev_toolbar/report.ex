defmodule PhoenixDevToolbar.Report do
  @moduledoc """
  Reads what the toolbar captured, without a browser: from IEx, a remote shell,
  or an agent that evaluates code in the running app (such as Tidewave's
  `project_eval`). See [ADR 13](https://github.com/zoten/phoenix_dev_toolbar/blob/main/adr/13-report-read-api.md).

      alias PhoenixDevToolbar.Report

      Report.latest(path: "/posts") |> Report.summary()
      #=> %{queries: %{count: 23, failed: 0, total_us: 4180, slowest: [...]},
      #     n_plus_one: [%{sql: "SELECT ... WHERE post_id = ?", count: 20, ...}], ...}

  ## Sessions and targets

  A session is one page view: a dead render request (`kind: :request`) or a
  LiveView process (`kind: :live_view`). `sessions/1` lists them newest first,
  `latest/1` returns the newest that matches.

  The reading functions take a *target*: a sid, a session from `sessions/1`, or
  a list of sids. A request's target includes the LiveView sessions that joined
  from it (its connected mount), so the dead render and the connected mount read
  as one page; pass `children: false` to read the request alone. A LiveView
  reached by live navigation is a session of its own.

  ## What you get

  Plain maps with atom keys, described by the types below. Durations are in
  microseconds, `at` is a `DateTime`. Values are already truncated and redacted
  when captured: you read what the panel shows. New keys may be added; renaming
  or removing one is a breaking change noted in the CHANGELOG.

  ## Limits

  Only what the Store still holds is readable: events are capped per session
  and expire after the TTL (10 minutes by default, `limits:` in the config). A
  session whose events were dropped or trimmed says so (`dropped`, `trimmed`).
  While the toolbar is disabled every function returns `[]` or `nil`.

  Every read runs in the caller's process and copies at most a few sessions'
  capped events: nothing runs in the host's request or LiveView processes.
  EXPLAIN and the process actions are not part of this API.
  """

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.NPlusOne
  alias PhoenixDevToolbar.Plugins
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @slowest 5
  @burst_gap_us 100_000
  @unattributed_origins 5
  @query_brief [:seq, :sid, :origin, :duration_us, :rows, :source, :n_plus_one?, :error]
  @callback_brief [
    :seq,
    :sid,
    :view,
    :component,
    :callback,
    :event,
    :inferred,
    :origin,
    :duration_us,
    :queries,
    :query_us,
    :error
  ]

  @typedoc "A session id."
  @type sid :: String.t()

  @typedoc """
  One page view. `owner` is the LiveView process (nil for a request), `parent`
  the session it came from (the request for a connected mount, the previous
  LiveView after live navigation). `events` is the number stored now.
  """
  @type session :: %{
          sid: sid(),
          kind: :request | :live_view,
          parent: sid() | nil,
          view: module() | nil,
          path: String.t() | nil,
          owner: pid() | nil,
          started_at: DateTime.t(),
          events: non_neg_integer(),
          dropped: non_neg_integer(),
          trimmed: non_neg_integer()
        }

  @typedoc "A sid, a session from `sessions/1`, or a list of sids."
  @type target :: sid() | session() | [sid()]

  @typedoc """
  One Ecto query. `rows` is set on success, `error` on failure. `times` holds
  Ecto's measurements (`:query_time`, `:queue_time`, `:decode_time`, ...) in
  microseconds. `origin` is the first stacktrace frame outside Ecto (nil unless
  the repo has `stacktrace: true`); when the stacktrace has no frame left (a
  query inside `Task.async` or `start_async`, whose `fn -> Repo.all(q) end`
  tail calls the repo) it is the task's function (`Mod.fun/arity`), else
  `"task in View.callback"` (plus the event name) of the callback that started
  the task, else nil. `span` is the callback the query ran in:
  see `callbacks/2`. `n_plus_one?` marks the query that reached the N+1
  threshold and every repetition after it, as the Ecto tab does.
  """
  @type query :: %{
          sid: sid(),
          seq: pos_integer(),
          span: non_neg_integer() | nil,
          at: DateTime.t(),
          duration_us: non_neg_integer() | nil,
          repo: String.t() | nil,
          sql: String.t() | nil,
          params: String.t() | nil,
          source: String.t() | nil,
          rows: non_neg_integer() | nil,
          error: String.t() | nil,
          times: %{atom() => non_neg_integer()},
          origin: String.t() | nil,
          stacktrace: [String.t()],
          n_plus_one?: boolean()
        }

  @typedoc """
  One LiveView or LiveComponent callback (`:mount`, `:handle_params`,
  `:handle_event`, `:handle_info`, `:update`, ...). `queries` and `query_us`
  count the queries run in it, its tasks included. `changes` is the assigns
  diff it produced (see `t:PhoenixDevToolbar.Truncate.changes/0`).

  LiveView emits no telemetry for `handle_info`, so `inferred: true` entries
  stand for it: the queries of a LiveView span no callback owns, split where two
  consecutive queries are more than 100 ms apart. Queries run by the LiveView
  process are `callback: :handle_info` (also PubSub reloads); queries run by a
  task (`assign_async`, `start_async`, `Task.start`) are `callback: :async`.
  They have no duration, event, params or changes, and `origin` is the origin
  of the first query (see `t:query/0`; nil on real callbacks). Several
  `handle_info` within 100 ms in one span merge into one entry; one that runs no
  query is invisible.
  """
  @type callback :: %{
          inferred: boolean(),
          sid: sid(),
          seq: pos_integer(),
          span: non_neg_integer() | nil,
          at: DateTime.t(),
          duration_us: non_neg_integer() | nil,
          callback: atom(),
          view: module() | nil,
          component: module() | nil,
          id: String.t() | nil,
          event: String.t() | nil,
          origin: String.t() | nil,
          params: String.t() | nil,
          changes: PhoenixDevToolbar.Truncate.changes() | nil,
          queries: non_neg_integer(),
          query_us: non_neg_integer(),
          error: String.t() | nil
        }

  @typedoc """
  A repeated query: the same SQL from the same origin run `count` times in one
  callback, in `callbacks` callbacks so far.
  """
  @type n_plus_one :: %{
          sql: String.t() | nil,
          origin: String.t() | nil,
          count: pos_integer(),
          callbacks: pos_integer(),
          sids: [sid()]
        }

  @typedoc "A failure: a request exception, a failed callback or render, a failed query. Request, LiveView and Ecto errors carry a formatted stacktrace in call order (LiveView: cut after the last host frame plus one, ADR 07)."
  @type error :: %{
          sid: sid(),
          seq: pos_integer(),
          at: DateTime.t(),
          source: :request | :live_view | :ecto,
          message: String.t(),
          origin: String.t() | nil,
          stacktrace: [String.t()]
        }

  @typedoc "A `t:query/0` without SQL, params, times and stacktrace: what `summary/2` lists by default."
  @type query_brief :: %{
          seq: pos_integer(),
          sid: sid(),
          origin: String.t() | nil,
          duration_us: non_neg_integer() | nil,
          rows: non_neg_integer() | nil,
          source: String.t() | nil,
          n_plus_one?: boolean(),
          error: String.t() | nil
        }

  @typedoc "A `t:callback/0` without params, assigns changes and times: what `summary/2` lists by default."
  @type callback_brief :: %{
          seq: pos_integer(),
          sid: sid(),
          view: module() | nil,
          component: module() | nil,
          callback: atom(),
          event: String.t() | nil,
          inferred: boolean(),
          origin: String.t() | nil,
          duration_us: non_neg_integer() | nil,
          queries: non_neg_integer(),
          query_us: non_neg_integer(),
          error: String.t() | nil
        }

  @typedoc "An `t:error/0` with its `origin` (its first host frame, else its first frame; nil when there is none)."
  @type error_brief :: %{
          seq: pos_integer(),
          sid: sid(),
          source: :request | :live_view | :ecto,
          message: String.t(),
          origin: String.t() | nil
        }

  @typedoc "The dead render request: its route and response."
  @type request :: %{
          method: String.t() | nil,
          path: String.t() | nil,
          route: String.t() | nil,
          handler: String.t() | nil,
          status: non_neg_integer() | nil,
          duration_us: non_neg_integer() | nil
        }

  @typedoc """
  A page at a glance. `sids` are the sessions read; `session` is the first.
  Each `slowest` list holds at most #{@slowest} items, slowest first. Items are
  briefs unless `summary/2` got `verbose: true`.
  `dropped` and `trimmed` add up the events lost to the caps.
  `callbacks` counts real callbacks only. `unattributed` counts the queries of
  LiveView sessions that no callback or render owns (usually `handle_info` or
  PubSub reloads), with its top #{@unattributed_origins} `origins` by time.
  """
  @type summary :: %{
          sids: [sid()],
          session: session(),
          request: request() | nil,
          queries: %{
            count: non_neg_integer(),
            failed: non_neg_integer(),
            total_us: non_neg_integer(),
            slowest: [query_brief() | query()]
          },
          n_plus_one: [n_plus_one()],
          unattributed: %{
            count: non_neg_integer(),
            total_us: non_neg_integer(),
            origins: [
              %{origin: String.t() | nil, count: pos_integer(), total_us: non_neg_integer()}
            ]
          },
          callbacks: %{
            count: non_neg_integer(),
            total_us: non_neg_integer(),
            slowest: [callback_brief() | callback()]
          },
          renders: %{count: non_neg_integer(), total_us: non_neg_integer()},
          errors: [error_brief() | error()],
          dropped: non_neg_integer(),
          trimmed: non_neg_integer()
        }

  ## Sessions

  @doc """
  Lists the sessions the Store holds, newest first.

  Options: `:path` (exact string or a `Regex`), `:view` (module), `:kind`
  (`:request` or `:live_view`), `:limit`.
  """
  @spec sessions(keyword()) :: [session()]
  def sessions(opts \\ []) do
    all_sessions()
    |> Enum.filter(&matches?(&1, opts))
    |> Enum.sort_by(& &1.started_at, :desc)
    |> limit(opts[:limit])
    |> Enum.map(&session/1)
  end

  @doc "The newest session matching `sessions/1` options, or nil."
  @spec latest(keyword()) :: session() | nil
  def latest(opts \\ []), do: opts |> Keyword.put(:limit, 1) |> sessions() |> List.first()

  ## Reads

  @doc """
  A page at a glance, or nil when no session of `target` is left.
  The slowest queries and callbacks and the errors are compact by default
  (`t:query_brief/0`, `t:callback_brief/0`, `t:error_brief/0`): read the detail
  with `queries/2`, `callbacks/2` and `errors/2`.
  Options: `verbose:` (true returns the full `t:query/0`, `t:callback/0` and
  `t:error/0` items), `children:` (see the module docs), `threshold:` (see `n_plus_one/2`).
  """
  @spec summary(target(), keyword()) :: summary() | nil
  def summary(target, opts \\ []) do
    case read(target, opts) do
      {[], _events} ->
        nil

      {[first | _] = sessions, events} ->
        owners = owners(events, sessions)
        queries = queries_of(events, owners, threshold(opts))
        callbacks = callbacks_of(events)
        orphans = orphans_of(events, sessions)
        renders = for %Event{plugin: :live_view, kind: :render} = event <- events, do: event
        brief = brief_fun(Keyword.get(opts, :verbose, false))

        %{
          sids: Enum.map(sessions, & &1.sid),
          session: session(first),
          request: request_of(events),
          queries: %{
            count: length(queries),
            failed: Enum.count(queries, &(&1.error != nil)),
            total_us: total(queries),
            slowest: queries |> slowest() |> Enum.map(&brief.(&1, @query_brief))
          },
          n_plus_one: n_plus_one_of(events, threshold(opts)),
          unattributed: unattributed(orphans, owners),
          callbacks: %{
            count: length(callbacks),
            total_us: total(callbacks),
            slowest: callbacks |> slowest() |> Enum.map(&brief.(&1, @callback_brief))
          },
          renders: %{count: length(renders), total_us: total(renders)},
          errors: events |> errors_of(owners) |> Enum.map(&error_item(&1, brief)),
          dropped: sessions |> Enum.map(& &1.dropped) |> Enum.sum(),
          trimmed: sessions |> Enum.map(& &1.trimmed) |> Enum.sum()
        }
    end
  end

  @doc """
  Every query of `target`, oldest first.
  Options: `children:`, `threshold:` (see `n_plus_one/2`).
  """
  @spec queries(target(), keyword()) :: [query()]
  def queries(target, opts \\ []) do
    {sessions, events} = read(target, opts)
    queries_of(events, owners(events, sessions), threshold(opts))
  end

  @doc """
  The repeated queries of `target`, most recent first.

  Options: `children:`, `threshold:` (repetitions in one callback, at least 2,
  or `false`). The threshold defaults to the Ecto plugin's `n_plus_one:` option.
  """
  @spec n_plus_one(target(), keyword()) :: [n_plus_one()]
  def n_plus_one(target, opts \\ []) do
    {_sessions, events} = read(target, opts)
    n_plus_one_of(events, threshold(opts))
  end

  @doc "Every LiveView and LiveComponent callback of `target`, oldest first. Option: `children:`."
  @spec callbacks(target(), keyword()) :: [callback()]
  def callbacks(target, opts \\ []) do
    {sessions, events} = read(target, opts)

    (callbacks_of(events) ++ inferred_of(events, sessions))
    |> Enum.sort_by(& &1.seq)
  end

  @doc "Every failure of `target`, oldest first. Option: `children:`."
  @spec errors(target(), keyword()) :: [error()]
  def errors(target, opts \\ []) do
    {sessions, events} = read(target, opts)
    errors_of(events, owners(events, sessions))
  end

  ## Reading the Store

  defp all_sessions do
    case PhoenixDevToolbar.enabled?() do
      true -> Store.sessions()
      false -> []
    end
  rescue
    # The Store is not running (its tables are gone).
    ArgumentError -> []
  end

  # The sessions of a target and their events, ordered by seq (global).
  defp read(target, opts) do
    all = all_sessions()
    by_sid = Map.new(all, &{&1.sid, &1})

    sessions =
      target
      |> sids()
      |> Enum.flat_map(&List.wrap(by_sid[&1]))
      |> with_children(all, Keyword.get(opts, :children, true))
      |> Enum.uniq_by(& &1.sid)

    events =
      sessions
      |> Enum.flat_map(&events(&1.sid))
      |> Enum.sort_by(& &1.seq)

    {sessions, events}
  end

  defp sids(sid) when is_binary(sid), do: [sid]
  defp sids(%{sid: sid}) when is_binary(sid), do: [sid]
  defp sids(sids) when is_list(sids), do: Enum.filter(sids, &is_binary/1)

  defp with_children(sessions, _all, false), do: sessions

  defp with_children(sessions, all, true) do
    Enum.flat_map(sessions, fn
      %Session{kind: :request, sid: sid} = request ->
        children = for %Session{kind: :live_view, parent: ^sid} = child <- all, do: child
        [request | Enum.sort_by(children, & &1.started_at)]

      session ->
        [session]
    end)
  end

  defp events(sid) do
    Store.events(sid)
  rescue
    ArgumentError -> []
  end

  defp matches?(%Session{} = session, opts) do
    Enum.all?(opts, fn
      {:path, %Regex{} = regex} -> is_binary(session.path) and Regex.match?(regex, session.path)
      {:path, path} -> session.path == path
      {:view, view} -> session.view == view
      {:kind, kind} -> session.kind == kind
      _other -> true
    end)
  end

  defp limit(sessions, limit) when is_integer(limit) and limit >= 0,
    do: Enum.take(sessions, limit)

  defp limit(sessions, _limit), do: sessions

  defp threshold(opts) do
    Keyword.get_lazy(opts, :threshold, fn ->
      Collector.plugins() |> List.keyfind(Plugins.Ecto, 0) |> ecto_threshold()
    end)
  end

  defp ecto_threshold({Plugins.Ecto, config}), do: Plugins.Ecto.n_plus_one(config)
  defp ecto_threshold(nil), do: Plugins.Ecto.n_plus_one(nil)

  ## Shapes

  defp session(%Session{} = session) do
    %{
      sid: session.sid,
      kind: session.kind,
      parent: session.parent,
      view: session.view,
      path: session.path,
      owner: session.owner,
      started_at: datetime(session.started_at),
      events: session.count,
      dropped: session.dropped,
      trimmed: session.trimmed
    }
  end

  defp queries_of(events, owners, threshold) do
    flagged = flagged(events, threshold)

    for %Event{plugin: :ecto, kind: :query, data: data} = event <- events do
      %{
        sid: event.sid,
        seq: event.seq,
        span: event.span,
        at: datetime(event.at),
        duration_us: event.duration,
        repo: module_name(data[:repo]),
        sql: data[:sql],
        params: data[:params],
        source: data[:source],
        rows: rows(data[:result]),
        error: query_error(data[:result]),
        times: data[:times] || %{},
        origin: origin(event, owners),
        stacktrace: data[:stacktrace] || [],
        n_plus_one?: MapSet.member?(flagged, event.seq)
      }
    end
  end

  # The seqs the Ecto tab tags N+1: the same fold, Clear markers included.
  defp flagged(events, threshold) do
    {_state, flagged} =
      events
      |> Enum.filter(&(&1.plugin == :ecto))
      |> Enum.reduce({NPlusOne.new(threshold), MapSet.new()}, fn event, {state, flagged} ->
        case NPlusOne.add(state, event) do
          {state, :ok} -> {state, flagged}
          {state, _detected} -> {state, MapSet.put(flagged, event.seq)}
        end
      end)

    flagged
  end

  defp n_plus_one_of(events, threshold) do
    events
    |> Enum.filter(&(&1.plugin == :ecto))
    |> Enum.reduce(NPlusOne.new(threshold), fn event, state ->
      {state, _result} = NPlusOne.add(state, event)
      state
    end)
    |> NPlusOne.groups()
    |> Enum.map(&Map.take(&1, [:sql, :origin, :count, :callbacks, :sids]))
  end

  defp callbacks_of(events) do
    db = query_time_by_span(events)

    for %Event{plugin: :live_view, kind: :callback, data: data} = event <- events do
      {queries, query_us} = Map.get(db, {event.sid, event.span}, {0, 0})

      %{
        sid: event.sid,
        seq: event.seq,
        span: event.span,
        at: datetime(event.at),
        duration_us: event.duration,
        callback: data[:callback],
        view: data[:view],
        component: data[:component],
        id: data[:id],
        inferred: false,
        origin: nil,
        event: data[:event],
        params: data[:params],
        changes: data[:changes],
        queries: queries,
        query_us: query_us,
        error: data[:error]
      }
    end
  end

  # Queries of LiveView sessions whose {sid, span} no callback or render owns.
  defp orphans_of(events, sessions) do
    live = for %Session{kind: :live_view, sid: sid} <- sessions, into: MapSet.new(), do: sid

    owned =
      for %Event{plugin: :live_view, kind: kind} = event <- events,
          kind in [:callback, :render],
          into: MapSet.new(),
          do: {event.sid, event.span}

    for %Event{plugin: :ecto, kind: :query} = event <- events,
        MapSet.member?(live, event.sid),
        not MapSet.member?(owned, {event.sid, event.span}),
        do: event
  end

  defp unattributed(orphans, owners) do
    origins =
      orphans
      |> Enum.group_by(&origin(&1, owners))
      |> Enum.map(fn {origin, queries} ->
        %{origin: origin, count: length(queries), total_us: total(queries)}
      end)
      |> Enum.sort_by(& &1.total_us, :desc)
      |> Enum.take(@unattributed_origins)

    %{count: length(orphans), total_us: total(orphans), origins: origins}
  end

  # First stacktrace frame, else the task's function, else the callback that
  # owns the query's `{sid, span}` (a Task child shares its caller's span), else
  # the session's view for a task query no callback owns (`start_async` runs
  # after its callback ended).
  defp origin(%Event{data: data} = event, owners) do
    List.first(data[:stacktrace] || []) || data[:initial_call] ||
      task_origin(data[:caller?], Map.get(owners, {event.sid, event.span}) || owners[event.sid])
  end

  defp task_origin(false, _owner), do: nil
  defp task_origin(_caller?, nil), do: nil
  defp task_origin(_caller?, view) when is_atom(view), do: "task in #{inspect(view)}"

  defp task_origin(_caller?, %{view: view, callback: callback} = data) do
    base = "task in #{inspect(data[:component] || view)}.#{callback}"

    case data[:event] do
      event when is_binary(event) -> base <> ~s( "#{event}")
      _none -> base
    end
  end

  defp owners(events, sessions) do
    views =
      for %{sid: sid, view: view} <- sessions, view, into: %{}, do: {sid, view}

    for %Event{plugin: :live_view, kind: :callback, data: data} = event <- events,
        into: views,
        do: {{event.sid, event.span}, data}
  end

  # One `handle_info` stand-in per burst of orphan queries (a span, split on gaps).
  defp inferred_of(events, sessions) do
    views = Map.new(sessions, &{&1.sid, &1.view})
    owners = owners(events, sessions)

    events
    |> orphans_of(sessions)
    |> Enum.group_by(&{&1.sid, &1.span, &1.data[:caller?] == true})
    |> Enum.flat_map(fn {{_sid, _span, caller?}, queries} ->
      queries |> bursts() |> Enum.map(&{caller?, &1})
    end)
    |> Enum.map(fn {caller?, [first | _] = burst} ->
      %{
        sid: first.sid,
        seq: first.seq,
        span: first.span,
        at: datetime(first.at),
        duration_us: nil,
        callback: inferred_callback(caller?),
        inferred: true,
        origin: origin(first, owners),
        view: views[first.sid],
        component: nil,
        id: nil,
        event: nil,
        params: nil,
        changes: nil,
        queries: length(burst),
        query_us: total(burst),
        error: nil
      }
    end)
  end

  # Queries of a task (`start_async`, `assign_async`, `Task.start`) come from
  # the caller's pid, the others from the LiveView process (`handle_info`).
  defp inferred_callback(true), do: :async
  defp inferred_callback(false), do: :handle_info

  defp bursts(queries) do
    queries
    |> Enum.sort_by(& &1.seq)
    |> Enum.chunk_while(
      [],
      fn
        query, [] ->
          {:cont, [query]}

        query, [last | _] = acc ->
          if query.at - last.at > @burst_gap_us do
            {:cont, Enum.reverse(acc), [query]}
          else
            {:cont, [query | acc]}
          end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp query_time_by_span(events) do
    for %Event{plugin: :ecto, kind: :query} = event <- events, reduce: %{} do
      acc ->
        Map.update(acc, {event.sid, event.span}, {1, event.duration || 0}, fn {n, us} ->
          {n + 1, us + (event.duration || 0)}
        end)
    end
  end

  defp request_of(events) do
    dispatch = find(events, :dispatch)
    response = find(events, :response)

    case {dispatch, response} do
      {nil, nil} ->
        nil

      _found ->
        data = Map.merge(data(dispatch), data(response))

        %{
          method: data[:method],
          path: data[:path],
          route: data[:route],
          handler: data[:handler],
          status: data[:status],
          duration_us: duration(response) || duration(dispatch)
        }
    end
  end

  defp find(events, kind), do: Enum.find(events, &(&1.plugin == :request and &1.kind == kind))

  defp data(nil), do: %{}
  defp data(%Event{data: data}), do: data

  defp duration(nil), do: nil
  defp duration(%Event{duration: duration}), do: duration

  defp errors_of(events, owners), do: Enum.flat_map(events, &error(&1, owners))

  defp error(%Event{plugin: :request, kind: :exception, data: data} = event, _owners),
    do: [error(event, :request, data[:error], data[:stacktrace], event.data[:origin])]

  defp error(%Event{plugin: :live_view, kind: kind, data: %{error: message}} = event, _owners)
       when kind in [:callback, :render] and is_binary(message),
       do: [error(event, :live_view, message, event.data[:stacktrace], event.data[:origin])]

  defp error(
         %Event{plugin: :ecto, kind: :query, data: %{result: {:error, message}}} = event,
         owners
       ),
       do: [error(event, :ecto, message, event.data[:stacktrace], origin(event, owners))]

  defp error(_event, _owners), do: []

  defp error(event, source, message, stacktrace, origin) do
    %{
      sid: event.sid,
      seq: event.seq,
      at: datetime(event.at),
      source: source,
      message: to_string(message),
      stacktrace: stacktrace || [],
      origin: origin || List.first(stacktrace || [])
    }
  end

  ## Helpers

  defp brief_fun(true), do: fn item, _keys -> item end
  defp brief_fun(_other), do: &Map.take/2

  defp error_item(error, brief) do
    brief.(error, [:seq, :sid, :source, :message])
    |> maybe_origin(error)
  end

  defp maybe_origin(%{stacktrace: _} = full, _error), do: full

  defp maybe_origin(item, error), do: Map.put(item, :origin, error.origin)

  defp slowest(items) do
    items |> Enum.sort_by(&(&1.duration_us || 0), :desc) |> Enum.take(@slowest)
  end

  defp total(items), do: items |> Enum.map(&(duration_us(&1) || 0)) |> Enum.sum()

  defp duration_us(%Event{duration: duration}), do: duration
  defp duration_us(%{duration_us: duration}), do: duration

  defp rows({:ok, rows}), do: rows
  defp rows(_result), do: nil

  defp query_error({:error, message}), do: to_string(message)
  defp query_error(_result), do: nil

  defp module_name(nil), do: nil
  defp module_name(module) when is_atom(module), do: inspect(module)

  defp datetime(us) when is_integer(us), do: DateTime.from_unix!(us, :microsecond)
end
