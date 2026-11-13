defmodule PhoenixDevToolbar.Mcp.Tools do
  @moduledoc false
  # The MCP tools (ADR 15): read-only views over `PhoenixDevToolbar.Report`.
  # Pure: no conn. Every result goes through `Mcp.Json.safe/1`.

  alias PhoenixDevToolbar.AssignsShape
  alias PhoenixDevToolbar.Mcp.Json
  alias PhoenixDevToolbar.PageLookup
  alias PhoenixDevToolbar.Report
  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.Truncate

  @type definition :: %{String.t() => term()}
  @type opts :: [base_url: String.t(), assigns_timeout: pos_integer()]

  @max_path 2048
  @group_by %{"caller" => :caller, "origin" => :origin, "callback" => :callback, "sql" => :sql}
  # What `Session.new_sid/0` makes (12 random bytes, URL-safe Base64).
  @captured_sid_shape ~r/\A[A-Za-z0-9_-]{16}\z/

  @sid_prop %{
    "type" => "string",
    "description" => "Page id (sid) from list_pages. Wins over path. Default: the newest page."
  }
  @path_prop %{
    "type" => "string",
    "description" => "Exact request path of the page, e.g. \"/posts\". Picks its newest capture."
  }
  @no_page_hint "Load the page first (a browser, or curl with Accept: text/html); captured data expires after 10 minutes."

  @doc "The tool definitions for `tools/list`."
  @spec list() :: [definition()]
  def list do
    [
      tool(
        "list_pages",
        "List captured pages",
        "Lists the pages the toolbar captured, newest first, each with a panel_url.",
        %{
          "path" => @path_prop,
          "path_prefix" => %{
            "type" => "string",
            "description" => "Only pages whose path starts with this."
          },
          "since" => %{
            "type" => "string",
            "description" =>
              "Only pages that started after this: a sid from an earlier list_pages, or an ISO 8601 timestamp."
          },
          "limit" => int_prop("Maximum pages to return.", 1, 50, 10)
        }
      ),
      tool(
        "page_summary",
        "Summarize a page",
        "A compact page at a glance: request, query count and time, N+1 findings, slowest queries and callbacks, errors. Query counts leave out framework noise (such as Phoenix.Ecto.CheckRepoStatus), counted in queries.noise. Items carry no SQL, params or assigns: pass verbose: true, or use page_queries and page_callbacks, for detail.",
        %{
          "sid" => @sid_prop,
          "path" => @path_prop,
          "verbose" => %{
            "type" => "boolean",
            "description" => "Full query, callback and error items instead of compact ones.",
            "default" => false
          }
        }
      ),
      tool(
        "page_queries",
        "List a page's Ecto queries",
        "The Ecto queries run for a page, with SQL, timings, origin (the Repo call site), caller (the LiveView, controller or on_mount frame that led to it; needs the repo's stacktrace: true), and the callback and event they ran in (span is the callback's seq group, as in page_callbacks; callback is request for a query outside any LiveView callback). noise tags framework queries (check_repo_status: Phoenix.Ecto.CheckRepoStatus), which page_summary leaves out of its counts. Rows are compact by default (no params, times, stacktrace or timestamp; sql cut to 160 bytes, sql_truncated says when): pass verbose: true for full rows. Filter with callback (e.g. handle_event, request), event, span, seq_from and seq_to (inclusive); total counts the filtered rows. group_by (caller, origin, callback or sql) returns groups instead of rows: each with key, count, total_us, n_plus_one and the first query's sql, most queries first (noise left out); limit applies to groups, total counts groups and queries_total the queries grouped. Use it to see where the queries of one click go: group_by caller with event, then read the rows of one group with verbose.",
        Map.merge(page_props(), %{
          "limit" => int_prop("Maximum queries to return.", 1, 200, 50),
          "sort" => sort_prop(),
          "callback" => %{
            "type" => "string",
            "description" => "Only queries run in this callback, e.g. handle_event or request."
          },
          "event" => %{
            "type" => "string",
            "description" => "Only queries run in this LiveView event, e.g. save."
          },
          "span" => nonneg_prop("Only queries of this callback span (seq group)."),
          "seq_from" => nonneg_prop("Only queries with seq >= this."),
          "seq_to" => nonneg_prop("Only queries with seq <= this."),
          "verbose" => %{
            "type" => "boolean",
            "description" =>
              "Full rows (full SQL, params, times, stacktrace) instead of compact ones.",
            "default" => false
          },
          "group_by" => %{
            "type" => "string",
            "enum" => Map.keys(@group_by),
            "description" =>
              "Group the queries by caller, origin, callback (with its event) or sql, instead of listing them."
          }
        })
      ),
      tool(
        "page_callbacks",
        "List a page's LiveView callbacks",
        "The LiveView and LiveComponent callbacks of a page (mount, handle_event, ...) with timings and assigns changes. Filter with callback (e.g. handle_event) and event. inferred: true entries stand for handle_info (or async task) queries no callback owns: their duration_us is null, never 0, so sum with a default; sort: \"slowest\" puts them last.",
        Map.merge(page_props(), %{
          "limit" => int_prop("Maximum callbacks to return.", 1, 200, 50),
          "sort" => sort_prop(),
          "callback" => %{
            "type" => "string",
            "description" => "Only this callback, e.g. handle_event or mount."
          },
          "event" => %{"type" => "string", "description" => "Only this LiveView event."}
        })
      ),
      tool(
        "page_n_plus_one",
        "Find N+1 queries on a page",
        "Repeated queries (same SQL from the same origin) found on a page. ran_in names the callbacks each repeated in (view, callback, event, seq, count); callers lists the distinct caller frames (the LiveView, controller or on_mount code above the Repo call) with counts, most frequent first.",
        page_props()
      ),
      tool(
        "page_errors",
        "List a page's errors",
        "Failures of a page: request exceptions, failed callbacks and renders, failed queries.",
        Map.merge(page_props(), %{"limit" => int_prop("Maximum errors to return.", 1, 100, 20)})
      ),
      tool(
        "recent_errors",
        "List recent errors across pages",
        "The newest failures across every captured page, newest first, each with its page path, page_sid (a connected mount reads as its request) and panel_url. Catches crashes the page lookups miss: a handle_info crash, another browser tab. Check it after a change.",
        %{
          "since" => %{
            "type" => "string",
            "description" =>
              "Only errors after this: a sid from an earlier list_pages or page_summary (errors after that page started, never that page's own, so a fixed page shows none of its old crashes) or an ISO 8601 timestamp."
          },
          "limit" => int_prop("Maximum errors to return.", 1, 100, 20)
        }
      ),
      tool(
        "compare_pages",
        "Compare two captures of a page",
        "Before and after a change: query, callback, render and unattributed count and time deltas, N+1 findings and errors fixed or new. Note a page's sid from page_summary, edit, reload the page, then call this with before: sid. The after page is the newest capture at that path started after before, unless after or path says otherwise.",
        %{
          "before" => %{
            "type" => "string",
            "description" =>
              "Sid of the earlier capture (from list_pages or page_summary), a string. To start from a path, call list_pages with path first."
          },
          "after" => %{
            "type" => "string",
            "description" =>
              "Sid of the later capture. Not with path. Default: see path. A connected mount sid reads as its page."
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "Exact request path: compare with its newest capture started after before. Default: before's own path. A different path than before's gets a warning."
          }
        }
      ),
      tool(
        "page_report",
        "Report a page as Markdown",
        "The page summary as Markdown, ready to read or paste into a bug report: request line, totals, N+1 findings, slowest queries (with SQL) and callbacks, errors.",
        page_props()
      ),
      tool(
        "page_assigns_shape",
        "Weigh a LiveView's assigns",
        "The size of each assign of the page's LiveView, largest first, with no values: type, length, words (memory) and stream?. Look for big lists that should be streams. A stream's words are what the server holds; its items live in the client. Read live: the page must be open in a browser. live_view_sid and live_view_path name the LiveView read, which may be a later one than the page's path after live navigation. note says the newest capture had no live LiveView and an open tab of the same path was read instead; warning says the tab navigated away from the page's path.",
        page_props()
      )
    ]
  end

  defp page_props, do: %{"sid" => @sid_prop, "path" => @path_prop}

  defp sort_prop do
    %{
      "type" => "string",
      "enum" => ["order", "slowest"],
      "default" => "order",
      "description" => "\"order\" (oldest first) or \"slowest\" (longest duration first)."
    }
  end

  defp nonneg_prop(description),
    do: %{"type" => "integer", "minimum" => 0, "description" => description}

  defp int_prop(description, min, max, default) do
    %{
      "type" => "integer",
      "minimum" => min,
      "maximum" => max,
      "default" => default,
      "description" => description
    }
  end

  defp tool(name, title, description, properties) do
    %{
      "name" => name,
      "title" => title,
      "description" => description,
      "inputSchema" => %{
        "type" => "object",
        "properties" => properties,
        "additionalProperties" => false
      },
      "annotations" => %{"readOnlyHint" => true}
    }
  end

  @doc """
  Runs a tool. `opts` needs `:base_url` (absolute, the plug's URL) for `panel_url`.
  An error message becomes an `isError` tool result.
  """
  @spec call(String.t(), term(), opts()) ::
          {:ok, %{String.t() => Json.json()}} | {:error, String.t()} | :unknown_tool
  def call(name, arguments, opts) when is_binary(name) do
    case Enum.find(list(), &(&1["name"] == name)) do
      nil -> :unknown_tool
      definition -> run(name, definition, arguments, opts)
    end
  end

  def call(_name, _arguments, _opts), do: :unknown_tool

  defp run(name, definition, arguments, opts) do
    with {:ok, args} <- check_args(arguments, definition),
         {:ok, result} <- execute(name, args, opts) do
      {:ok, Json.safe(result)}
    end
  end

  defp execute("list_pages", args, opts) do
    with {:ok, path} <- string_arg(args, "path"),
         {:ok, prefix} <- string_arg(args, "path_prefix"),
         :ok <- exclusive(path, prefix),
         {:ok, since} <- since_arg(args),
         {:ok, limit} <- int_arg(args, "limit", 10, 1, 50) do
      filter = Keyword.merge(PageLookup.filter(path: path, path_prefix: prefix), since)
      pages = pages(filter, limit)

      {:ok, %{"pages" => Enum.map(pages, &Map.put(&1, :panel_url, panel_url(opts, &1.sid)))}}
    end
  end

  defp execute("page_summary", args, opts) do
    with {:ok, verbose} <- bool_arg(args, "verbose"),
         {:ok, sid} <- resolve(args) do
      case Report.summary(sid, verbose: verbose) do
        nil -> {:error, no_page()}
        summary -> {:ok, Map.put(summary, :panel_url, panel_url(opts, sid))}
      end
    end
  end

  defp execute("page_report", args, opts) do
    with {:ok, sid} <- resolve(args) do
      url = panel_url(opts, sid)

      case Report.markdown(sid, panel_url: url) do
        nil -> {:error, no_page()}
        markdown -> {:ok, %{sid: sid, panel_url: url, markdown: markdown}}
      end
    end
  end

  # A live read of the host LiveView, in a task with a timeout (AssignsShape).
  defp execute("page_assigns_shape", args, opts) do
    with {:ok, requested} <- resolve(args) do
      {sid, note} = live_page(requested, args)

      case AssignsShape.read(sid, Keyword.get(opts, :assigns_timeout, 2_000)) do
        {:ok, shape} ->
          result = Map.merge(shape, %{sid: sid, panel_url: panel_url(opts, sid)})
          {:ok, result |> put_note(note) |> navigation_warning(session_path(sid))}

        {:error, :timeout} ->
          {:error, "Reading the assigns timed out: the LiveView is busy. Try again in a moment."}

        {:error, :no_live_view} ->
          {:error,
           "The page has no LiveView (a dead render only, e.g. a controller page or a curl " <>
             "capture): there are no assigns to read."}

        {:error, :gone} ->
          {:error,
           "The LiveView is gone (tab closed or navigated away): open the page in a browser, " <>
             "then call page_assigns_shape again (assigns are read live)."}
      end
    end
  end

  defp execute("compare_pages", args, opts) do
    with {:ok, before_sid} <- sid_arg(args, "before", true),
         {:ok, after_sid} <- sid_arg(args, "after", false),
         {:ok, path} <- string_arg(args, "path"),
         :ok <- after_xor_path(after_sid, path),
         {:ok, after_sid} <- after_page(before_sid, after_sid, path) do
      case Report.compare(before_sid, after_sid) do
        nil ->
          {:error, "A page expired before it could be compared. " <> @no_page_hint}

        comparison ->
          in_order(comparison, opts)
      end
    end
  end

  defp execute("page_queries", args, opts) do
    with {:ok, filters} <- filter_args(args, [:callback, :event], [:span, :seq_from, :seq_to]),
         {:ok, verbose} <- bool_arg(args, "verbose"),
         {:ok, group_by} <- group_by_arg(args) do
      queries(group_by, filters, verbose, args, opts)
    end
  end

  defp execute("page_callbacks", args, opts) do
    with {:ok, filters} <- filter_args(args, [:callback, :event], []) do
      rows("callbacks", &Report.callbacks(&1, filters), args, opts, & &1)
    end
  end

  defp execute("page_n_plus_one", args, opts) do
    with {:ok, sid} <- resolve(args) do
      {:ok,
       %{
         "sid" => sid,
         "panel_url" => panel_url(opts, sid),
         "n_plus_one" => Report.n_plus_one(sid)
       }}
    end
  end

  defp execute("page_errors", args, opts) do
    with {:ok, limit} <- int_arg(args, "limit", 20, 1, 100),
         {:ok, sid} <- resolve(args) do
      errors = Report.errors(sid)

      {:ok,
       %{
         "sid" => sid,
         "panel_url" => panel_url(opts, sid),
         "total" => length(errors),
         "returned" => min(limit, length(errors)),
         "errors" => Enum.take(errors, limit)
       }}
    end
  end

  defp execute("recent_errors", args, opts) do
    with {:ok, since} <- since_arg(args),
         {:ok, limit} <- int_arg(args, "limit", 20, 1, 100) do
      all = Report.recent_errors(Keyword.put(since, :limit, nil))

      errors =
        all
        |> Enum.take(limit)
        |> Enum.map(&Map.put(&1, :panel_url, panel_url(opts, &1.page_sid)))

      {:ok, %{"total" => length(all), "returned" => length(errors), "errors" => errors}}
    end
  end

  # Without an explicit sid, a newest capture that cannot be read (a curl, a dead
  # render, a closed tab) yields to the newest page at the same path with a live
  # LiveView, and the result says which sid it read.
  defp live_page(requested, args) do
    with nil <- Map.get(args, "sid"),
         false <- AssignsShape.live?(requested),
         {:ok, filter} <- path_filter(args, requested),
         %{} = live <- find_live(filter) do
      {live.sid,
       "The newest capture (#{requested}) has no live LiveView: read the page #{live.sid} instead."}
    else
      _no_alternative -> {requested, nil}
    end
  end

  # The requested path, else the newest page's own path: never another page.
  # No path at all (the page expired meanwhile) means no alternative.
  defp path_filter(args, requested) do
    with {:ok, path} <- string_arg(args, "path"),
         path when is_binary(path) <- path || session_path(requested),
         do: {:ok, PageLookup.filter(path: path)}
  end

  defp find_live(filter) do
    filter
    |> pages(50)
    |> Enum.map(&%{sid: PageLookup.root(&1.sid)})
    |> Enum.find(&AssignsShape.live?(&1.sid))
  end

  defp put_note(result, nil), do: result
  defp put_note(result, note), do: Map.put(result, :note, note)

  # Live navigation: the LiveView read belongs to another path than the page.
  defp navigation_warning(%{live_view_path: lv_path} = result, page_path)
       when is_binary(lv_path) and is_binary(page_path) and lv_path != page_path do
    Map.put(
      result,
      :warning,
      "The tab navigated to #{lv_path}: these assigns are that LiveView's, not #{page_path}'s."
    )
  end

  defp navigation_warning(result, _page_path), do: result

  defp in_order(%{before: b, after: a} = comparison, opts) do
    case DateTime.compare(a.started_at, b.started_at) do
      :lt ->
        {:error,
         "after is older than before, so the deltas would be flipped: swap them " <>
           "(before is the earlier capture)."}

      _later ->
        {:ok,
         %{
           comparison
           | before: Map.put(b, :panel_url, panel_url(opts, b.sid)),
             after: Map.put(a, :panel_url, panel_url(opts, a.sid))
         }}
    end
  end

  # A sid argument that must be well formed and still captured.
  defp sid_arg(args, key, required?) do
    case Map.get(args, key) do
      nil when required? ->
        {:error,
         "#{key} is required: the sid of the earlier capture (page_summary or list_pages)."}

      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        captured_sid(value, key)

      other ->
        {:error, page_sid_message(key, other)}
    end
  end

  defp page_sid_message(key, %{"path" => path}) when is_binary(path) do
    path = inspect(String.slice(path, 0, 200))

    "#{key}: a page sid string (from list_pages or page_summary), got an object. " <>
      "For the page at #{path}, call list_pages with path: #{path} and pass its sid" <>
      if(key == "before", do: "; to pick the after page by path, use path: #{path}.", else: ".")
  end

  defp page_sid_message(key, other),
    do:
      "#{key}: a page sid string (from list_pages or page_summary), got #{kind(other)}. " <>
        ~s(To compare by path, pass before: <sid> and path: "/posts".)

  defp captured_sid(value, key) do
    with true <- PageLookup.valid_sid?(value),
         sid when is_binary(sid) <- existing(value) do
      {:ok, sid}
    else
      _unusable ->
        {:error,
         "#{key}: no captured page with that sid (sessions are capped and expire after 10 minutes). " <>
           "Reload the page, then call page_summary for a new sid."}
    end
  end

  defp after_xor_path(after_sid, path) when is_binary(after_sid) and is_binary(path),
    do: {:error, "Use after or path, not both."}

  defp after_xor_path(_after_sid, _path), do: :ok

  defp after_page(_before_sid, after_sid, _path) when is_binary(after_sid), do: {:ok, after_sid}

  # The newest page at the path that started after `before`.
  defp after_page(before_sid, nil, path) do
    case path || session_path(before_sid) do
      nil ->
        {:error, no_page_after(nil)}

      path ->
        case pages(Keyword.merge(PageLookup.filter(path: path), since: before_sid), 1) do
          [%{sid: sid}] -> {:ok, sid}
          [] -> {:error, no_page_after(path)}
        end
    end
  end

  defp session_path(sid) do
    case Store.session(sid) do
      {:ok, session} -> session.path
      :error -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp no_page_after(path) do
    "No page captured at #{String.slice(to_string(path), 0, 200)} after before. " <>
      "Reload the page in the browser (or curl it with Accept: text/html) after your edit, then call compare_pages again."
  end

  # A sid, else an ISO 8601 timestamp.
  defp since_arg(args) do
    case Map.get(args, "since") do
      nil ->
        {:ok, []}

      value when is_binary(value) ->
        parse_since(value)

      _other ->
        {:error, since_message(false)}
    end
  end

  # A sid must still be in the Store; otherwise it may be a timestamp.
  defp parse_since(value) do
    with true <- PageLookup.valid_sid?(value),
         sid when is_binary(sid) <- existing(value) do
      {:ok, since: sid}
    else
      _not_a_live_sid -> parse_timestamp(value)
    end
  end

  defp parse_timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, since: datetime}
      {:error, _reason} -> {:error, since_message(Regex.match?(@captured_sid_shape, value))}
    end
  end

  defp since_message(true),
    do:
      "since: that sid is no longer captured (sessions are capped and expire). " <>
        "Pass its started_at (ISO 8601, such as 2026-11-11T10:00:00Z) instead; " <>
        "accepted: a captured page sid or an ISO 8601 timestamp."

  defp since_message(false),
    do:
      "since: that is not a captured page sid or an ISO 8601 time. Pass a sid from " <>
        "list_pages or a timestamp such as 2026-11-11T10:00:00Z."

  defp exclusive(path, prefix) when is_binary(path) and is_binary(prefix),
    do: {:error, "Use path or path_prefix, not both."}

  defp exclusive(_path, _prefix), do: :ok

  # A Store that is restarting (its tables missing) holds no pages.
  defp pages(filter, limit) do
    filter |> Report.sessions() |> reject_mounts() |> Enum.take(limit)
  rescue
    ArgumentError -> []
  end

  defp queries(nil, filters, verbose, args, opts),
    do: rows("queries", &Report.queries(&1, filters), args, opts, &compact(&1, verbose))

  defp queries(by, filters, _verbose, args, opts) do
    with {:ok, limit} <- int_arg(args, "limit", 50, 1, 200),
         {:ok, sid} <- resolve(args) do
      groups = Report.query_groups(sid, by, filters)

      {:ok,
       %{
         "sid" => sid,
         "panel_url" => panel_url(opts, sid),
         "total" => length(groups),
         "queries_total" => groups |> Enum.map(& &1.count) |> Enum.sum(),
         "returned" => min(limit, length(groups)),
         "groups" => Enum.take(groups, limit)
       }}
    end
  end

  defp rows(key, reader, args, opts, shape) do
    with {:ok, limit} <- int_arg(args, "limit", 50, 1, 200),
         {:ok, sort} <- sort_arg(args),
         {:ok, sid} <- resolve(args) do
      all = sid |> reader.() |> sort_rows(sort)

      {:ok,
       %{
         "sid" => sid,
         "panel_url" => panel_url(opts, sid),
         "total" => length(all),
         "returned" => min(limit, length(all)),
         key => all |> Enum.take(limit) |> Enum.map(shape)
       }}
    end
  end

  @compact_keys ~w(seq sid span callback event origin caller duration_us rows source n_plus_one? noise error)a
  @sql_preview 160

  defp compact(row, true), do: row

  defp compact(row, false) do
    sql = Truncate.prefix(row.sql || "", @sql_preview)

    row
    |> Map.take(@compact_keys)
    |> Map.merge(%{sql: row.sql && sql, sql_truncated: is_binary(row.sql) and sql != row.sql})
  end

  # Filters as Report options: strings stay strings (never atoms), integers
  # are non-negative.
  defp filter_args(args, strings, integers) do
    with {:ok, text} <- collect(args, strings, &string_arg/2),
         {:ok, numbers} <- collect(args, integers, &filter_int/2) do
      {:ok, text ++ numbers}
    end
  end

  defp collect(args, keys, reader) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case reader.(args, Atom.to_string(key)) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, [{key, value} | acc]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp filter_int(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      other -> {:error, "#{key}: a non-negative integer, got #{int_got(other)}."}
    end
  end

  defp sort_rows(rows, "order"), do: rows

  # Slowest first, rows without a duration last.
  defp sort_rows(rows, "slowest") do
    {timed, untimed} = Enum.split_with(rows, &is_integer(&1.duration_us))
    Enum.sort_by(timed, & &1.duration_us, :desc) ++ untimed
  end

  # A connected mount belongs to its request's page (see `PageLookup.newest/1`).
  defp reject_mounts(sessions) do
    request_sids =
      for %{kind: :request, sid: sid} <- Store.sessions(), into: MapSet.new(), do: sid

    Enum.reject(sessions, fn page ->
      page.kind == :live_view and is_binary(page.parent) and page.parent in request_sids
    end)
  end

  # Arguments

  defp check_args(nil, _definition), do: {:ok, %{}}

  defp check_args(args, definition) when is_map(args) and not is_struct(args) do
    known = definition |> get_in(["inputSchema", "properties"]) |> Map.keys()

    case Map.keys(args) -- known do
      [] ->
        {:ok, args}

      unknown ->
        {:error,
         "Unknown argument(s): #{Enum.map_join(unknown, ", ", &safe_key/1)}. " <>
           "Accepted: #{accepted(known)}."}
    end
  end

  defp check_args(_args, _definition), do: {:error, "arguments must be an object"}

  defp accepted([]), do: "none"
  defp accepted(known), do: known |> Enum.sort() |> Enum.join(", ")

  defp safe_key(key) when is_binary(key), do: inspect(String.slice(key, 0, 40))
  defp safe_key(key), do: inspect(key, limit: 5)

  defp string_arg(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      other -> {:error, "#{key}: #{expected(key)}, got #{kind(other)}."}
    end
    |> check_size(key)
  end

  defp expected("sid"),
    do:
      ~s(a page sid string from list_pages or page_summary; to pick a page by path, use path: "/posts")

  defp expected("path"), do: ~s(an exact request path string, such as "/posts")
  defp expected("path_prefix"), do: ~s(a path prefix string, such as "/admin")
  defp expected(_key), do: "a string"

  # What an argument was, for an error message: the type, never the value.
  defp kind(value) when is_map(value), do: "an object"
  defp kind(value) when is_list(value), do: "an array"
  defp kind(value) when is_boolean(value), do: "a boolean"
  defp kind(value) when is_number(value), do: "a number"
  defp kind(value) when is_binary(value), do: "a string"
  defp kind(_value), do: "null"

  defp check_size({:ok, value} = ok, key) when key in ["path", "path_prefix"] do
    case is_binary(value) and byte_size(value) > @max_path do
      true -> {:error, "#{key} must be at most #{@max_path} bytes"}
      false -> ok
    end
  end

  defp check_size(result, _key), do: result

  defp bool_arg(args, key) do
    case Map.get(args, key, false) do
      value when is_boolean(value) -> {:ok, value}
      other -> {:error, "#{key}: true or false, got #{kind(other)}."}
    end
  end

  defp int_arg(args, key, default, min, max) do
    case Map.get(args, key, default) do
      value when is_integer(value) and value >= min and value <= max -> {:ok, value}
      other -> {:error, "#{key}: an integer from #{min} to #{max}, got #{int_got(other)}."}
    end
  end

  # The four names are mapped explicitly: a string never becomes an atom.
  defp group_by_arg(args) do
    case Map.get(args, "group_by") do
      nil -> {:ok, nil}
      name when is_binary(name) and is_map_key(@group_by, name) -> {:ok, @group_by[name]}
      _other -> {:error, "group_by: one of #{@group_by |> Map.keys() |> Enum.join(", ")}."}
    end
  end

  defp sort_arg(args) do
    case Map.get(args, "sort", "order") do
      sort when sort in ["order", "slowest"] -> {:ok, sort}
      _other -> {:error, ~s[sort: "order" (oldest first) or "slowest" (longest first).]}
    end
  end

  # sid > path > newest page
  defp resolve(args) do
    with {:ok, sid} <- string_arg(args, "sid"),
         {:ok, path} <- string_arg(args, "path") do
      resolve_page(sid, path)
    end
  end

  defp resolve_page(nil, nil), do: found(PageLookup.newest())

  defp resolve_page(nil, path) do
    case PageLookup.newest(path: path) do
      nil -> {:error, no_page_at(path)}
      sid -> {:ok, sid}
    end
  end

  defp resolve_page(sid, _path) do
    case PageLookup.valid_sid?(sid) do
      true -> found(sid |> existing() |> root())
      false -> {:error, "sid: a page sid from list_pages ([A-Za-z0-9_-], 1 to 64 characters)."}
    end
  end

  defp existing(sid) do
    case Store.session(sid) do
      {:ok, _session} -> sid
      :error -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # An explicit mount sid reads its whole page (PageLookup.root/1).
  defp root(nil), do: nil
  defp root(sid), do: PageLookup.root(sid)

  defp found(nil), do: {:error, no_page()}
  defp found(sid), do: {:ok, sid}

  defp int_got(value) when is_integer(value), do: Integer.to_string(value)
  defp int_got(value), do: kind(value)

  defp no_page, do: "No page captured. " <> @no_page_hint

  defp no_page_at(path) do
    "No captured page at #{String.slice(path, 0, 200)}. list_pages shows the captured paths; " <>
      "a live patch keeps its LiveView's mount path. Captured data expires after 10 minutes."
  end

  defp panel_url(opts, sid), do: Keyword.get(opts, :base_url, "") <> "/panel?sid=" <> sid
end
