defmodule PhoenixDevToolbar.EctoExport do
  @moduledoc false
  # The Ecto tab's JSON export (ADR 08): a page's queries as a map JSON
  # encodes as is (string keys; strings, numbers, booleans, nil, lists).
  # Copy sends the map through push_event/3; Download is `request/1`, answered
  # by PhoenixDevToolbar.Plug on a same-origin URL (a blob: link in the iframe
  # is blocked by a host's `frame-src` in Firefox), encoded with the host's
  # JSON library (`Phoenix.json_library/0`): the toolbar adds none.
  #
  # `:short` keeps what reproduces a query (SQL, params, location), `:full`
  # every captured detail, plus EXPLAIN plans when an `:explain` function is
  # given: run one query at a time, at most `:max_explains` of them within
  # `:budget_ms`, the rest marked skipped. Params are the stored, redacted
  # string: the raw params kept for EXPLAIN are never exported.

  # Jason pretty prints the file when it is the host's JSON library.
  @compile {:no_warn_undefined, Jason}

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Explain
  alias PhoenixDevToolbar.NPlusOne
  alias PhoenixDevToolbar.Plugins
  alias PhoenixDevToolbar.Store

  @max_explains 50
  @budget_ms 15_000
  # A page is its request and its LiveViews (PhoenixDevToolbar.Page): a few sids.
  @max_sids 4

  @type format :: :short | :full
  @type json :: String.t() | number() | boolean() | nil | [json()] | %{String.t() => json()}
  @type explain_fun :: (Event.t() -> {:ok, String.t()} | {:error, Explain.error() | String.t()})

  @doc """
  The export of `events` (the page's Ecto events, any order). Options:
  `:root` (the request sid: its queries are `"http"`), `:path`, `:threshold`
  (the N+1 detector's, 5 by default), `:explain`, `:max_explains`, `:budget_ms`.
  """
  @spec build([Event.t()], format(), keyword()) :: %{String.t() => json()}
  def build(events, format, opts \\ []) do
    events = Enum.sort_by(events, & &1.seq)
    queries = queries(events, format, opts)

    %{
      "format" => Atom.to_string(format),
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "path" => opts[:path],
      "count" => length(queries),
      "queries" => queries
    }
  end

  @doc """
  The export of a page: the Ecto events of `sids` in the Store, with the
  Ecto plugin's `config` (repos for EXPLAIN, the N+1 threshold).
  """
  @spec page(
          %{root: String.t() | nil, sids: [String.t()], path: String.t() | nil},
          format(),
          boolean(),
          map() | nil
        ) :: %{String.t() => json()}
  def page(%{root: root, sids: sids, path: path}, format, explain?, config) do
    config = config || %{}

    events =
      Enum.flat_map(sids, &for(%Event{plugin: :ecto} = event <- Store.events(&1), do: event))

    opts =
      [root: root, path: path || latest_path(sids), threshold: Plugins.Ecto.n_plus_one(config)] ++
        explain_opt(format, explain?, Map.get(config, :repos, []))

    build(events, format, opts)
  end

  # A page without its LiveView yet has no path of its own (Page): the
  # request's, as Download reads it.
  defp latest_path(sids) do
    Enum.reduce(sids, nil, fn sid, path ->
      case Store.session(sid) do
        {:ok, session} -> session.path || path
        :error -> path
      end
    end)
  end

  defp explain_opt(:full, true, repos), do: [explain: &Explain.run(&1, repos)]
  defp explain_opt(_format, _explain?, _repos), do: []

  @doc """
  The Download answer, from the query params of
  `<path>/export/ecto.json?format=short|full&explain=true&root=SID&sids=SID,SID`:
  `{:ok, filename, body}`, `{:error, 400}` for bad params or `{:error, 404}`
  for a page or an Ecto plugin that is not there. The sids are the access
  key, as for the panel.
  """
  @spec request(map()) :: {:ok, String.t(), iodata()} | {:error, 400 | 404}
  def request(params) do
    with {:ok, format} <- format(params["format"]),
         {:ok, root} <- sid(params["root"]),
         {:ok, sids} <- sids(params["sids"]),
         true <- root in sids || {:error, 400},
         {:ok, path} <- known(sids),
         {:ok, config} <- ecto_config() do
      page = %{root: root, sids: sids, path: path}
      export = page(page, format, params["explain"] == "true", config)
      {:ok, filename(format, export["exported_at"]), encode(export)}
    end
  end

  @doc "The file name of an export: `ecto-queries-<format>-<yyyymmddThhmmss>.json`."
  @spec filename(format(), String.t()) :: String.t()
  def filename(format, exported_at) do
    stamp = exported_at |> String.replace(~r/[^0-9T]/, "") |> String.slice(0, 15)
    "ecto-queries-#{format}-#{stamp}.json"
  end

  defp format("short"), do: {:ok, :short}
  defp format("full"), do: {:ok, :full}
  defp format(_other), do: {:error, 400}

  defp sid(sid) when is_binary(sid) and byte_size(sid) in 1..64, do: {:ok, sid}
  defp sid(_other), do: {:error, 400}

  defp sids(sids) when is_binary(sids) and byte_size(sids) <= 65 * @max_sids do
    sids = String.split(sids, ",")

    case length(sids) <= @max_sids and Enum.all?(sids, &match?({:ok, _sid}, sid(&1))) do
      true -> {:ok, sids}
      false -> {:error, 400}
    end
  end

  defp sids(_other), do: {:error, 400}

  # Every sid a session in the Store; the path is the page's latest.
  defp known(sids) do
    Enum.reduce_while(sids, {:ok, nil}, fn sid, {:ok, path} ->
      case Store.session(sid) do
        {:ok, session} -> {:cont, {:ok, session.path || path}}
        :error -> {:halt, {:error, 404}}
      end
    end)
  end

  defp ecto_config do
    case List.keyfind(Collector.plugins(), Plugins.Ecto, 0) do
      {Plugins.Ecto, config} -> {:ok, config}
      nil -> {:error, 404}
    end
  end

  defp encode(export) do
    case Phoenix.json_library() do
      Jason -> Jason.encode_to_iodata!(export, pretty: true)
      library -> library.encode_to_iodata!(export)
    end
  end

  defp queries(events, :short, _opts) do
    for %Event{kind: :query} = event <- events, do: short(event)
  end

  defp queries(events, :full, opts) do
    flagged = n_plus_one(events, Keyword.get(opts, :threshold, 5))
    queries = Enum.filter(events, &(&1.kind == :query))
    plans = explain_all(queries, opts)

    for event <- queries do
      Map.merge(short(event), full(event, opts[:root], flagged, plans))
    end
  end

  defp short(%Event{seq: seq, data: data}) do
    %{
      "seq" => seq,
      "sql" => data[:sql],
      "params" => data[:params],
      "location" => location(data[:stacktrace])
    }
  end

  defp full(%Event{data: data} = event, root, flagged, plans) do
    %{
      "at" => event.at |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601(),
      "duration_us" => event.duration,
      "phase" => phase(event.sid, root),
      "repo" => repo(data[:repo]),
      "source" => data[:source],
      "result" => result(data[:result]),
      "times" => Map.new(data[:times] || %{}, fn {key, us} -> {Atom.to_string(key), us} end),
      "caller" => data[:caller?] == true,
      "n_plus_one" => MapSet.member?(flagged, event.seq),
      "stacktrace" => data[:stacktrace] || [],
      "explain" => explain(event, plans)
    }
  end

  defp location([first | _rest]), do: first
  defp location(_stacktrace), do: nil

  defp phase(root, root), do: "http"
  defp phase(_sid, _root), do: "live"

  defp repo(nil), do: nil
  defp repo(repo), do: inspect(repo)

  defp result({:ok, rows}), do: %{"ok" => rows}
  defp result({:error, message}), do: %{"error" => message}
  defp result(_other), do: nil

  # The seqs the Ecto tab tags N+1: the same fold, Clear markers included.
  defp n_plus_one(events, threshold) do
    {_state, flagged} =
      Enum.reduce(events, {NPlusOne.new(threshold), MapSet.new()}, fn event, {state, flagged} ->
        case NPlusOne.add(state, event) do
          {state, :ok} -> {state, flagged}
          {state, _detected} -> {state, MapSet.put(flagged, event.seq)}
        end
      end)

    flagged
  end

  defp explain_all(queries, opts) do
    case opts[:explain] do
      nil ->
        :not_requested

      fun ->
        max = Keyword.get(opts, :max_explains, @max_explains)
        deadline = now_ms() + Keyword.get(opts, :budget_ms, @budget_ms)

        queries
        |> Enum.filter(&Explain.explainable?/1)
        |> Enum.reduce_while(%{}, &explain_within(&1, &2, fun, max, deadline))
    end
  end

  defp explain_within(event, plans, fun, max, deadline) do
    case map_size(plans) < max and now_ms() < deadline do
      true -> {:cont, Map.put(plans, event.seq, fun.(event))}
      false -> {:halt, plans}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp explain(_event, :not_requested), do: %{"status" => "not_requested"}

  defp explain(event, plans) do
    case Map.fetch(plans, event.seq) do
      {:ok, result} -> plan(result)
      :error -> unexplained(event)
    end
  end

  defp unexplained(event) do
    case Explain.explainable?(event) do
      true -> %{"status" => "skipped"}
      false -> %{"status" => "not_explainable", "reason" => Explain.unexplainable_reason(event)}
    end
  end

  defp plan({:ok, text}), do: %{"status" => "ok", "plan" => text}
  defp plan({:error, reason}), do: %{"status" => "error", "reason" => Explain.reason(reason)}
end
