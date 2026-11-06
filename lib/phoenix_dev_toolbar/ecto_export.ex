defmodule PhoenixDevToolbar.EctoExport do
  @moduledoc false
  # The Ecto tab's JSON export (ADR 08): a page's queries as a map JSON
  # encodes as is (string keys; strings, numbers, booleans, nil, lists). It is
  # not encoded here: the map goes through push_event/3, which Phoenix encodes
  # with the host's JSON library, and the browser formats it.
  #
  # `:short` keeps what reproduces a query (SQL, params, location), `:full`
  # every captured detail, plus EXPLAIN plans when an `:explain` function is
  # given: run one query at a time, at most `:max_explains` of them within
  # `:budget_ms`, the rest marked skipped. Params are the stored, redacted
  # string: the raw params kept for EXPLAIN are never exported.

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Explain
  alias PhoenixDevToolbar.NPlusOne

  @max_explains 50
  @budget_ms 15_000

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
