defmodule PhoenixDevToolbar.Mcp.Tools do
  @moduledoc false
  # The MCP tools (ADR 15): read-only views over `PhoenixDevToolbar.Report`.
  # Pure: no conn. Every result goes through `Mcp.Json.safe/1`.

  alias PhoenixDevToolbar.Mcp.Json
  alias PhoenixDevToolbar.PageLookup
  alias PhoenixDevToolbar.Report
  alias PhoenixDevToolbar.Store

  @type definition :: %{String.t() => term()}
  @type opts :: [base_url: String.t()]

  @max_path 2048

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
          "limit" => int_prop("Maximum pages to return.", 1, 50, 10)
        }
      ),
      tool(
        "page_summary",
        "Summarize a page",
        "A page at a glance: request, query count and time, N+1 findings, slowest callbacks, errors.",
        %{"sid" => @sid_prop, "path" => @path_prop}
      ),
      tool(
        "page_queries",
        "List a page's Ecto queries",
        "The Ecto queries run for a page, with SQL, timings and origin.",
        Map.merge(page_props(), %{
          "limit" => int_prop("Maximum queries to return.", 1, 200, 50),
          "sort" => sort_prop()
        })
      ),
      tool(
        "page_callbacks",
        "List a page's LiveView callbacks",
        "The LiveView and LiveComponent callbacks of a page (mount, handle_event, ...) with timings and assigns changes.",
        Map.merge(page_props(), %{
          "limit" => int_prop("Maximum callbacks to return.", 1, 200, 50),
          "sort" => sort_prop()
        })
      ),
      tool(
        "page_n_plus_one",
        "Find N+1 queries on a page",
        "Repeated queries (same SQL from the same origin) found on a page.",
        page_props()
      ),
      tool(
        "page_errors",
        "List a page's errors",
        "Failures of a page: request exceptions, failed callbacks and renders, failed queries.",
        Map.merge(page_props(), %{"limit" => int_prop("Maximum errors to return.", 1, 100, 20)})
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
         {:ok, limit} <- int_arg(args, "limit", 10, 1, 50) do
      pages = pages([path: path, path_prefix: prefix] |> PageLookup.filter(), limit)

      {:ok, %{"pages" => Enum.map(pages, &Map.put(&1, :panel_url, panel_url(opts, &1.sid)))}}
    end
  end

  defp execute("page_summary", args, opts) do
    with {:ok, sid} <- resolve(args) do
      case Report.summary(sid) do
        nil -> {:error, no_page()}
        summary -> {:ok, Map.put(summary, :panel_url, panel_url(opts, sid))}
      end
    end
  end

  defp execute("page_queries", args, opts), do: rows("queries", &Report.queries/1, args, opts)

  defp execute("page_callbacks", args, opts),
    do: rows("callbacks", &Report.callbacks/1, args, opts)

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

  defp exclusive(path, prefix) when is_binary(path) and is_binary(prefix),
    do: {:error, "Use path or path_prefix, not both."}

  defp exclusive(_path, _prefix), do: :ok

  # A Store that is restarting (its tables missing) holds no pages.
  defp pages(filter, limit) do
    filter |> Report.sessions() |> reject_mounts() |> Enum.take(limit)
  rescue
    ArgumentError -> []
  end

  defp rows(key, reader, args, opts) do
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
         key => Enum.take(all, limit)
       }}
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
      [] -> {:ok, args}
      unknown -> {:error, "Unknown argument(s): #{Enum.map_join(unknown, ", ", &safe_key/1)}"}
    end
  end

  defp check_args(_args, _definition), do: {:error, "arguments must be an object"}

  defp safe_key(key) when is_binary(key), do: inspect(String.slice(key, 0, 40))
  defp safe_key(key), do: inspect(key, limit: 5)

  defp string_arg(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, "#{key} must be a string"}
    end
    |> check_size(key)
  end

  defp check_size({:ok, value} = ok, key) when key in ["path", "path_prefix"] do
    case is_binary(value) and byte_size(value) > @max_path do
      true -> {:error, "#{key} must be at most #{@max_path} bytes"}
      false -> ok
    end
  end

  defp check_size(result, _key), do: result

  defp int_arg(args, key, default, min, max) do
    case Map.get(args, key, default) do
      value when is_integer(value) and value >= min and value <= max -> {:ok, value}
      _other -> {:error, "#{key} must be an integer between #{min} and #{max}"}
    end
  end

  defp sort_arg(args) do
    case Map.get(args, "sort", "order") do
      sort when sort in ["order", "slowest"] -> {:ok, sort}
      _other -> {:error, "sort must be \"order\" or \"slowest\""}
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
      true -> found(existing(sid))
      false -> {:error, "sid must match [A-Za-z0-9_-], 1 to 64 characters"}
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

  defp found(nil), do: {:error, no_page()}
  defp found(sid), do: {:ok, sid}

  defp no_page, do: "No page captured. " <> @no_page_hint

  defp no_page_at(path) do
    "No captured page at #{String.slice(path, 0, 200)}. list_pages shows the captured paths; " <>
      "a live patch keeps its LiveView's mount path. Captured data expires after 10 minutes."
  end

  defp panel_url(opts, sid), do: Keyword.get(opts, :base_url, "") <> "/panel?sid=" <> sid
end
