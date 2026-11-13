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
  alias PhoenixDevToolbar.PageLookup
  alias PhoenixDevToolbar.Plugins
  alias PhoenixDevToolbar.QueryFrames
  alias PhoenixDevToolbar.Report.Compare
  alias PhoenixDevToolbar.Report.Markdown
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @slowest 5
  @compare_cap Compare.cap()
  @burst_gap_us 100_000
  @unattributed_origins 5
  @n_plus_one_callers 5
  @query_brief [
    :seq,
    :sid,
    :callback,
    :origin,
    :caller,
    :duration_us,
    :rows,
    :source,
    :n_plus_one?,
    :error
  ]
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
  the task, else nil. `caller` is the web-layer frame that led to the query
  (see `t:place/0`), from the same stacktrace.

  `span` is the callback the query ran in (see `callbacks/2`), named by
  `callback` and `event`: a LiveView or LiveComponent callback, `:render`,
  `:handle_info` or `:async` for a LiveView query no callback owns (as the
  inferred entries of `callbacks/2`), `:request` for a request query outside
  any LiveView callback (the plug pipeline, a controller).

  `noise` tags a framework query: `"check_repo_status"` for
  `Phoenix.Ecto.CheckRepoStatus` (the `schema_migrations` checks of every dev
  request), `"framework"` when no stacktrace frame is outside the framework.
  `summary/2` leaves them out of its counts. `n_plus_one?` marks the query
  that reached the N+1 threshold and every repetition after it, as the Ecto
  tab does.
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
          caller: String.t() | nil,
          callback: atom(),
          event: String.t() | nil,
          noise: String.t() | nil,
          stacktrace: [String.t()],
          n_plus_one?: boolean()
        }

  @typedoc """
  Where a query's `caller` is found: the first stacktrace frame (the origin
  included) of a module matching the Ecto plugin's `caller_modules:` (by
  default a `*Web` namespace, a `*Live` or `*Controller` module) or of a
  LiveView callback (`mount/3`, `handle_params/3`, `handle_event/3`,
  `handle_info/2`, `handle_async/3`, `on_mount/4`), outside Phoenix and
  the other framework modules; else the frame after the origin; nil without a
  stacktrace. A frame string, like `origin`.
  """
  @type place :: String.t() | nil

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
  query is invisible. Their `duration_us` is nil, never 0: sum or sort with
  `duration_us || 0` (the MCP `sort: "slowest"` puts them last).
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
  callback, in `callbacks` callbacks so far. `ran_in` names those callbacks
  (the last 10, newest first; `callback` and `event` as on `t:query/0`, `seq`
  the callback's own, nil for an inferred one, `count` the repetitions in it).
  `callers` are the distinct `caller` frames of its repetitions in those
  callbacks, most frequent first (at most #{@n_plus_one_callers}): the code
  that led to the repeated call, where `origin` is the Repo call site.
  """
  @type n_plus_one :: %{
          sql: String.t() | nil,
          origin: String.t() | nil,
          count: pos_integer(),
          callbacks: pos_integer(),
          sids: [sid()],
          ran_in: [ran_in()],
          callers: [%{frame: String.t(), count: pos_integer()}]
        }

  @typedoc "One callback an N+1 group repeated in: see `t:n_plus_one/0`."
  @type ran_in :: %{
          sid: sid(),
          span: non_neg_integer() | nil,
          seq: pos_integer() | nil,
          view: module() | nil,
          component: module() | nil,
          callback: atom(),
          event: String.t() | nil,
          count: pos_integer()
        }

  @typedoc "A failure: a request exception, a failed callback or render, a failed query. Request, LiveView and Ecto errors carry a formatted stacktrace in call order (LiveView: cut after the last host frame plus one, ADR 07). `stack_args`, parallel to `stacktrace` (the call arguments of a frame, redacted and bounded), is present only when the developer set `stack_args: [agents: true]` (ADR 03)."
  @type error :: %{
          required(:sid) => sid(),
          required(:seq) => pos_integer(),
          required(:at) => DateTime.t(),
          required(:source) => :request | :live_view | :ecto,
          required(:message) => String.t(),
          required(:origin) => String.t() | nil,
          required(:stacktrace) => [String.t()],
          optional(:stack_args) => [String.t() | nil]
        }

  @typedoc "A `t:query/0` without SQL, params, times and stacktrace: what `summary/2` lists by default."
  @type query_brief :: %{
          seq: pos_integer(),
          sid: sid(),
          callback: atom(),
          origin: String.t() | nil,
          caller: String.t() | nil,
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

  @typedoc "An `t:error_brief/0` with its `at` time and the `path` of its session, from `recent_errors/1`."
  @type recent_error :: %{
          seq: pos_integer(),
          sid: sid(),
          source: :request | :live_view | :ecto,
          message: String.t(),
          origin: String.t() | nil,
          at: DateTime.t(),
          path: String.t() | nil,
          page_sid: sid()
        }

  @typedoc "An option of `recent_errors/1`."
  @type recent_errors_opt ::
          {:since, sid() | DateTime.t()} | {:limit, non_neg_integer() | nil}

  @typedoc "An option of `sessions/1`."
  @type sessions_opt ::
          {:path, String.t() | Regex.t()}
          | {:view, module()}
          | {:kind, :request | :live_view}
          | {:limit, non_neg_integer() | nil}
          | {:since, sid() | DateTime.t()}

  @typedoc "An option of `callbacks/2`."
  @type callbacks_opt ::
          {:children, boolean()}
          | {:callback, atom() | String.t()}
          | {:event, String.t()}

  @typedoc "An option of `queries/2`."
  @type queries_opt ::
          callbacks_opt()
          | {:threshold, pos_integer() | false}
          | {:span, non_neg_integer()}
          | {:seq_from, non_neg_integer()}
          | {:seq_to, non_neg_integer()}

  @typedoc "An option of `summary/2`."
  @type summary_opt ::
          {:verbose, boolean()}
          | {:children, boolean()}
          | {:threshold, pos_integer() | false}

  @typedoc "An option of `compare/3` and `markdown/2`."
  @type compare_opt :: {:children, boolean()} | {:threshold, pos_integer() | false}

  @typedoc "An option of `markdown/2`."
  @type markdown_opt :: compare_opt() | {:panel_url, String.t() | nil}

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
  `queries` leaves out framework noise (see `t:query/0`), counted apart in
  `queries.noise`. `callbacks` counts real callbacks only. `unattributed` counts the queries of
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
            slowest: [query_brief() | query()],
            noise: tally()
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

  @typedoc "Count and time of one kind of work, on one side of a `t:comparison/0`."
  @type tally :: %{count: non_neg_integer(), total_us: non_neg_integer()}

  @typedoc "The same work on both pages: `delta` is `after` minus `before`, so negative means less."
  @type tally_change :: %{
          before: tally(),
          after: tally(),
          delta: %{count: integer(), total_us: integer()}
        }

  @typedoc """
  Two pages side by side (`compare/3`). Findings are matched by key, not by
  position, so an edit that only moves a line does not change them:
  `n_plus_one` on SQL plus origin, `errors` on source plus origin, both
  without the line number, plus the first line of the message with pids,
  references, ports and numbers normalized. `fixed` ones were only in
  `before`, `new` ones only in `after`, `still` counts the distinct ones in
  both (a count only: a group dropping from 50 repetitions to 10 is still).
  Each list holds distinct keys, at most #{@compare_cap}; `fixed_total` and
  `new_total` count them all. An error carries `count`, its occurrences.
  `before` and `after` say which `kind` and `sids` were read; a `warning`
  is present when the two differ in kind, session count or path, or when
  either side lost events (`dropped`, `trimmed`).
  """
  @type comparison :: %{
          required(:before) => compared_side(),
          required(:after) => compared_side(),
          required(:queries) => tally_change(),
          required(:callbacks) => tally_change(),
          required(:renders) => tally_change(),
          required(:unattributed) => tally_change(),
          required(:n_plus_one) => findings(n_plus_one()),
          required(:errors) => findings(error_brief() | error()),
          optional(:warning) => String.t()
        }

  @typedoc "One side of a `t:comparison/0`."
  @type compared_side :: %{
          sid: sid(),
          path: String.t() | nil,
          started_at: DateTime.t(),
          kind: :request | :live_view,
          sids: [sid()],
          dropped: non_neg_integer(),
          trimmed: non_neg_integer()
        }

  @typedoc "Findings fixed, new and kept between two pages."
  @type findings(item) :: %{
          fixed: [item],
          fixed_total: non_neg_integer(),
          new: [item],
          new_total: non_neg_integer(),
          still: non_neg_integer()
        }

  ## Sessions

  @doc """
  Lists the sessions the Store holds, newest first.

  Options: `:path` (exact string or a `Regex`), `:view` (module), `:kind`
  (`:request` or `:live_view`), `:limit`, `:since` (a sid: only sessions that
  started after that page, a connected mount reading as its request; the
  request's own mount is listed since it started later, use `compare/3` to
  read a whole page; a `DateTime`: only sessions that started after it; an
  unknown sid or any other value gives `[]`, never a raise).
  """
  @spec sessions([sessions_opt()]) :: [session()]
  def sessions(opts \\ []) do
    all = all_sessions()

    all
    |> Enum.filter(&matches?(&1, opts))
    |> since(all, opts[:since])
    |> Enum.sort_by(& &1.started_at, :desc)
    |> limit(opts[:limit])
    |> Enum.map(&session/1)
  end

  @doc "The newest session matching `sessions/1` options, or nil."
  @spec latest([sessions_opt()]) :: session() | nil
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
  @spec summary(target(), [summary_opt()]) :: summary() | nil
  def summary(target, opts \\ []) do
    case read(target, opts) do
      {[], _events} ->
        nil

      {[first | _] = sessions, events} ->
        owners = owners(events, sessions)
        places = places(events, sessions)
        {noise, queries} = events |> queries_of(owners, places, threshold(opts)) |> noise()
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
            slowest: queries |> slowest() |> Enum.map(&brief.(&1, @query_brief)),
            noise: %{count: length(noise), total_us: total(noise)}
          },
          n_plus_one: n_plus_one_of(events, places, threshold(opts)),
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
  A page as Markdown, for an agent or a bug report, or nil when no session of
  `target` is left. Built from `summary/2`, so it holds at most what the summary
  lists: the request line, query and callback totals, the N+1 findings, the
  slowest queries and callbacks, unattributed origins and errors. Empty
  sections are left out, table cells are escaped to one line, SQL that is long
  or multi-line goes in a fenced block. Options: `children:`, `threshold:`,
  `panel_url:` (a link to the page in the panel: the report ends with a footer
  naming the page's sid and the link, so a pasted report leads back to it).
  """
  @spec markdown(target(), [markdown_opt()]) :: String.t() | nil
  def markdown(target, opts \\ []) do
    summary_opts = Keyword.take(opts, [:children, :threshold])

    case summary(target, Keyword.put(summary_opts, :verbose, true)) do
      nil -> nil
      summary -> summary |> Markdown.render() |> footer(summary, opts[:panel_url])
    end
  end

  defp footer(markdown, _summary, nil), do: markdown

  defp footer(markdown, %{sids: [sid | _]}, panel_url) when is_binary(panel_url),
    do: markdown <> "\n---\nsid `#{sid}`, panel: #{panel_url}\n"

  @doc """
  Two pages side by side, for checking a change: what got faster, which N+1
  and errors were fixed, which are new. Built from two `summary/2` calls, so
  `before` and `after` are targets and the options (`threshold:`, `children:`)
  pass through. A connected mount reads as its request. Nil when either page
  is gone. See `t:comparison/0` for the matching rules and the `warning`.
  """
  @spec compare(target(), target(), [compare_opt()]) :: comparison() | nil
  def compare(before_target, after_target, opts \\ []) do
    opts = Keyword.take(opts, [:threshold, :children])

    with %{} = b <- before_target |> root() |> summary(opts),
         %{} = a <- after_target |> root() |> summary(opts) do
      Compare.build(b, a)
    end
  end

  # A connected mount reads as its request (`PageLookup.root/1`).
  defp root(sid) when is_binary(sid), do: PageLookup.root(sid)
  defp root(%{sid: sid}) when is_binary(sid), do: PageLookup.root(sid)
  defp root(target), do: target

  @doc """
  Every query of `target`, oldest first.

  Options: `children:`, `threshold:` (see `n_plus_one/2`), and filters, which
  all must match: `callback:` (an atom or a string, compared as a string:
  `"handle_event"`, `"request"`), `event:` (a LiveView event name), `span:`
  (a callback's seq group, as on `callbacks/2`) and `seq_from:` / `seq_to:`
  (inclusive; seq is global, so they window a page across its sessions).
  Filters apply after the read: `n_plus_one?` still counts every query.
  """
  @spec queries(target(), [queries_opt()]) :: [query()]
  def queries(target, opts \\ []) do
    {sessions, events} = read(target, opts)

    events
    |> queries_of(owners(events, sessions), places(events, sessions), threshold(opts))
    |> matching(opts, [:callback, :event, :span, :seq_from, :seq_to])
  end

  defp matching(rows, opts, keys) do
    filters = for key <- keys, value = Keyword.get(opts, key), value != nil, do: {key, value}
    Enum.filter(rows, fn row -> Enum.all?(filters, &match_filter?(row, &1)) end)
  end

  defp match_filter?(row, {:callback, value}),
    do: Atom.to_string(row.callback) == to_string(value)

  defp match_filter?(row, {:event, value}), do: row.event == value
  defp match_filter?(row, {:span, value}), do: row.span == value
  defp match_filter?(row, {:seq_from, value}), do: row.seq >= value
  defp match_filter?(row, {:seq_to, value}), do: row.seq <= value

  @doc """
  The repeated queries of `target`, most recent first.

  Options: `children:`, `threshold:` (repetitions in one callback, at least 2,
  or `false`). The threshold defaults to the Ecto plugin's `n_plus_one:` option.
  """
  @spec n_plus_one(target(), keyword()) :: [n_plus_one()]
  def n_plus_one(target, opts \\ []) do
    {sessions, events} = read(target, opts)
    n_plus_one_of(events, places(events, sessions), threshold(opts))
  end

  @doc """
  Every LiveView and LiveComponent callback of `target`, oldest first.
  Options: `children:`, and the filters `callback:` and `event:` (as on
  `queries/2`).
  """
  @spec callbacks(target(), [callbacks_opt()]) :: [callback()]
  def callbacks(target, opts \\ []) do
    {sessions, events} = read(target, opts)

    (callbacks_of(events) ++ inferred_of(events, sessions))
    |> Enum.sort_by(& &1.seq)
    |> matching(opts, [:callback, :event])
  end

  @doc "Every failure of `target`, oldest first. Option: `children:`."
  @spec errors(target(), keyword()) :: [error()]
  def errors(target, opts \\ []) do
    {sessions, events} = read(target, opts)
    errors_of(events, owners(events, sessions))
  end

  @doc """
  The newest failures across every page the Store holds, newest first, as
  `t:recent_error/0` items: an `t:error_brief/0` plus the session `path`, the
  `page_sid` (its root: a connected mount reads as its request) and
  the error's `at`. It sees LiveView callbacks (a `handle_info` crash, another
  tab) that no page lookup would point at.

  Options: `:since` (a sid: errors after that page started, the page's own
  sessions, its request and connected mount, never listed, so a fix that
  leaves the old crash behind reads as fixed and the old tab's later events
  do not hide other pages; a `DateTime`: errors after it; an unknown sid or
  any other value gives `[]`) and `:limit` (default 20, `nil` for all). Reads
  the events of at most the capped number of sessions the Store holds.
  """
  @spec recent_errors([recent_errors_opt()]) :: [recent_error()]
  def recent_errors(opts \\ []) do
    all = all_sessions()

    case cursor(all, opts[:since]) do
      :none ->
        []

      {after_us, own_page} ->
        all
        |> Enum.reject(&own_page?(&1, own_page))
        |> Enum.flat_map(&session_errors(&1, after_us))
        |> Enum.sort_by(&{DateTime.to_unix(&1.at, :microsecond), &1.seq}, :desc)
        |> limit(Keyword.get(opts, :limit, 20))
        |> Enum.map(&recent_error/1)
    end
  end

  defp cursor(_all, nil), do: {0, nil}
  defp cursor(_all, %DateTime{} = at), do: {DateTime.to_unix(at, :microsecond), nil}

  # The page's root start: its own sessions are excluded, the rest is "after".
  defp cursor(all, sid) when is_binary(sid) do
    root = PageLookup.root(sid)

    case Enum.find(all, &(&1.sid == root)) do
      %Session{started_at: us} = session -> {us, session}
      nil -> :none
    end
  end

  defp cursor(_all, _other), do: :none

  defp own_page?(_session, nil), do: false
  defp own_page?(%Session{sid: sid}, %Session{sid: sid}), do: true

  # Only a request's connected mount belongs to it (like `with_children/3`): a
  # LiveView's navigated child is the next page.
  defp own_page?(%Session{kind: :live_view, parent: sid}, %Session{kind: :request, sid: sid}),
    do: true

  defp own_page?(_session, _root), do: false

  defp session_errors(%Session{} = session, after_us) do
    events = events(session.sid)

    events
    |> errors_of(owners(events, [session]))
    |> Enum.filter(&(DateTime.to_unix(&1.at, :microsecond) > after_us))
    |> Enum.map(&Map.put(&1, :path, session.path))
  end

  defp recent_error(error) do
    error
    |> error_item(&Map.take/2)
    |> Map.merge(Map.take(error, [:at, :path]))
    |> Map.put(:page_sid, PageLookup.root(error.sid))
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

  defp since(sessions, _all, nil), do: sessions

  defp since(sessions, _all, %DateTime{} = cursor),
    do: after_us(sessions, DateTime.to_unix(cursor, :microsecond))

  defp since(sessions, all, sid) when is_binary(sid) do
    root = PageLookup.root(sid)

    case Enum.find(all, &(&1.sid == root)) do
      %Session{started_at: us} -> after_us(sessions, us)
      nil -> []
    end
  end

  defp since(_sessions, _all, _other), do: []

  defp after_us(sessions, us), do: Enum.filter(sessions, &(&1.started_at > us))

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

  defp caller_patterns do
    case List.keyfind(Collector.plugins(), Plugins.Ecto, 0) do
      {Plugins.Ecto, config} -> Plugins.Ecto.caller_modules(config)
      nil -> Plugins.Ecto.caller_modules(nil)
    end
  end

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

  defp queries_of(events, owners, places, threshold) do
    flagged = flagged(events, threshold)

    for %Event{plugin: :ecto, kind: :query, data: data} = event <- events do
      place = place(event, places)
      stacktrace = data[:stacktrace] || []

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
        caller: QueryFrames.caller(stacktrace, places.patterns),
        callback: place.callback,
        event: place.event,
        noise: QueryFrames.noise(data),
        stacktrace: stacktrace,
        n_plus_one?: MapSet.member?(flagged, event.seq)
      }
    end
  end

  # {noise, counted}: framework queries are counted apart.
  defp noise(queries), do: Enum.split_with(queries, &is_binary(&1.noise))

  # Where the queries ran: the callback (first) or render owning each
  # {sid, span}, the session kinds and views for the others, and the caller
  # patterns of the Ecto plugin.
  defp places(events, sessions) do
    owned =
      for %Event{plugin: :live_view, kind: kind, data: data} = event <- events,
          kind in [:callback, :render],
          reduce: %{} do
        acc ->
          Map.put_new(acc, {event.sid, event.span}, %{
            seq: event.seq,
            view: data[:view],
            component: data[:component],
            callback: if(kind == :render, do: :render, else: data[:callback]),
            event: data[:event],
            kind: kind
          })
      end

    # A callback wins over a render of the same span.
    callbacks =
      for {key, %{kind: :callback} = place} <- owned, into: %{}, do: {key, place}

    %{
      spans: Map.merge(owned, callbacks),
      sessions: Map.new(sessions, &{&1.sid, {&1.kind, &1.view}}),
      patterns: caller_patterns()
    }
  end

  defp place(%Event{sid: sid, span: span, data: data}, places),
    do: place_of(sid, span, data[:caller?] == true, places)

  defp place_of(sid, span, caller?, %{spans: spans, sessions: sessions}) do
    case spans do
      %{{^sid, ^span} => place} -> place
      _unowned -> unowned(Map.get(sessions, sid), caller?)
    end
  end

  defp unowned({:live_view, view}, caller?),
    do: %{seq: nil, view: view, component: nil, callback: inferred_callback(caller?), event: nil}

  defp unowned(_request, _caller?),
    do: %{seq: nil, view: nil, component: nil, callback: :request, event: nil}

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

  defp n_plus_one_of(events, places, threshold) do
    ecto = Enum.filter(events, &(&1.plugin == :ecto))

    groups =
      ecto
      |> Enum.reduce(NPlusOne.new(threshold), fn event, state ->
        {state, _result} = NPlusOne.add(state, event)
        state
      end)
      |> NPlusOne.groups()

    by_key =
      case groups do
        [] ->
          %{}

        _groups ->
          for(%Event{kind: :query} = e <- ecto, do: e) |> Enum.group_by(&NPlusOne.group_key/1)
      end

    Enum.map(groups, fn group ->
      group
      |> Map.take([:sql, :origin, :count, :callbacks, :sids])
      |> Map.put(:ran_in, Enum.map(group.spans, &ran_in(&1, places)))
      |> Map.put(:callers, callers(group, Map.get(by_key, group.key, []), places.patterns))
    end)
  end

  defp ran_in(%{sid: sid, span: span, caller?: caller?, count: count}, places) do
    place = place_of(sid, span, caller?, places)

    %{
      sid: sid,
      span: span,
      seq: place.seq,
      view: place.view,
      component: place.component,
      callback: place.callback,
      event: place.event,
      count: count
    }
  end

  # The caller frames of the group's repetitions, in the spans it repeated in.
  defp callers(group, queries, patterns) do
    spans = MapSet.new(group.spans, &{&1.sid, &1.span})

    queries
    |> Enum.filter(&MapSet.member?(spans, {&1.sid, &1.span}))
    |> Enum.map(&QueryFrames.caller(&1.data[:stacktrace] || [], patterns))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {frame, count} -> {-count, frame} end)
    |> Enum.take(@n_plus_one_callers)
    |> Enum.map(fn {frame, count} -> %{frame: frame, count: count} end)
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
    |> maybe_stack_args(event.data[:stack_args], Collector.stack_args())
  end

  # Call arguments reach agents only when the developer asked (ADR 03).
  defp maybe_stack_args(error, args, %{agents: true}) when is_list(args),
    do: Map.put(error, :stack_args, args)

  defp maybe_stack_args(error, _args, _settings), do: error

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
