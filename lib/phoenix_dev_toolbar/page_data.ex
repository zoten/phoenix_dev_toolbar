defmodule PhoenixDevToolbar.PageData do
  @moduledoc false
  # What the panel reads about a page (ADR 03, ADR 05): its events, the gaps
  # in them (dropped, trimmed) and the plugins the collector disabled. Reads
  # ETS and persistent_term only; the Store's tables vanish while it restarts,
  # so every read falls back to "nothing".

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @type gaps :: %{
          dropped: non_neg_integer(),
          trimmed: non_neg_integer(),
          by_plugin: %{String.t() => non_neg_integer()}
        }

  @doc "Every stored event of `sids`, in seq order."
  @spec read_all([Session.sid()]) :: [Event.t()]
  def read_all(sids) do
    sids
    |> Enum.flat_map(fn sid -> safe(fn -> Store.events(sid) end, []) end)
    |> Enum.sort_by(& &1.seq)
  end

  @doc "The events of each sid with a seq above its low mark in `lows`, in seq order."
  @spec read_since([Session.sid()], %{Session.sid() => non_neg_integer()}) :: [Event.t()]
  def read_since(sids, lows) do
    sids
    |> Enum.flat_map(fn sid -> safe(fn -> Store.events(sid, Map.get(lows, sid, 0)) end, []) end)
    |> Enum.sort_by(& &1.seq)
  end

  @doc "The session `sid`, or `:error` (also while the Store restarts)."
  @spec session(Session.sid()) :: {:ok, Session.t()} | :error
  def session(sid), do: safe(fn -> Store.session(sid) end, :error)

  @doc """
  Events over the flood guard budget (dropped) and the oldest events past the
  per plugin and per session caps (trimmed) are counted, not stored: the gaps the
  panel shows, in total and per plugin (by tab id).
  """
  @spec gaps([Session.sid()]) :: gaps()
  def gaps(sids) do
    Enum.reduce(sids, %{dropped: 0, trimmed: 0, by_plugin: %{}}, fn sid, gaps ->
      case session(sid) do
        {:ok, session} ->
          %{
            dropped: gaps.dropped + session.dropped,
            trimmed: gaps.trimmed + session.trimmed,
            by_plugin: add_trimmed(gaps.by_plugin, safe(fn -> Store.plugin_counts(sid) end, %{}))
          }

        :error ->
          gaps
      end
    end)
  end

  @doc """
  The plugins the collector disabled after their collect/3 raised, by tab id,
  with the error banner (a persistent_term read each: no copy).
  """
  @spec quarantined([{module(), term()}]) :: %{String.t() => String.t()}
  def quarantined(plugins) do
    for {plugin, _config} <- plugins,
        banner = Collector.quarantine_reason(plugin),
        into: %{},
        do: {Atom.to_string(plugin.id()), banner}
  end

  @doc "Runs `fun`, returning `fallback` when the Store's tables are missing."
  @spec safe((-> result), fallback) :: result | fallback when result: term(), fallback: term()
  def safe(fun, fallback) do
    fun.()
  rescue
    ArgumentError -> fallback
  end

  defp add_trimmed(acc, counts) do
    Enum.reduce(counts, acc, fn {plugin, %{trimmed: n}}, acc ->
      Map.update(acc, Atom.to_string(plugin), n, &(&1 + n))
    end)
  end
end
