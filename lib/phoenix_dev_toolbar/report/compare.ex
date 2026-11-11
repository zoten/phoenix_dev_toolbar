defmodule PhoenixDevToolbar.Report.Compare do
  @moduledoc false
  # The matching and totals of `PhoenixDevToolbar.Report.compare/3`, built from
  # two `Report.summary/2` results.

  @cap 20

  @doc "The most findings listed per `fixed` / `new`."
  @spec cap() :: pos_integer()
  def cap, do: @cap

  @spec build(PhoenixDevToolbar.Report.summary(), PhoenixDevToolbar.Report.summary()) ::
          PhoenixDevToolbar.Report.comparison()
  def build(b, a) do
    {fixed, new, still} = diff(b.n_plus_one, a.n_plus_one, &n_plus_one_key/1)
    {errors_fixed, errors_new, errors_still} = diff(b.errors, a.errors, &error_key/1)

    comparison = %{
      before: side(b),
      after: side(a),
      queries: tally_change(b.queries, a.queries),
      callbacks: tally_change(b.callbacks, a.callbacks),
      renders: tally_change(b.renders, a.renders),
      unattributed: tally_change(b.unattributed, a.unattributed),
      n_plus_one: with_totals(fixed, new, still),
      errors: with_totals(errors_fixed, errors_new, errors_still)
    }

    maybe_warn(comparison)
  end

  defp side(summary) do
    summary.session
    |> Map.take([:sid, :path, :started_at, :kind])
    |> Map.put(:sids, summary.sids)
    |> Map.put(:dropped, summary.dropped)
    |> Map.put(:trimmed, summary.trimmed)
  end

  defp maybe_warn(%{before: b, after: a} = comparison) do
    case warnings(b, a) do
      [] -> comparison
      warnings -> Map.put(comparison, :warning, Enum.join(warnings, " "))
    end
  end

  defp warnings(b, a) do
    kind =
      b.kind != a.kind or length(b.sids) != length(a.sids)

    path = b.path != a.path
    lost = b.dropped + b.trimmed + a.dropped + a.trimmed > 0

    Enum.filter(
      [
        kind &&
          "before is a #{b.kind} read from #{length(b.sids)} session(s), after is a #{a.kind} " <>
            "read from #{length(a.sids)}: totals may not be comparable (live navigation, or a " <>
            "dead render without its connected mount).",
        path &&
          "before is #{inspect(b.path)}, after is #{inspect(a.path)}: different pages, so " <>
            "fixed and new reflect the pages, not a change.",
        lost &&
          "events were lost to the caps (before: #{b.dropped} dropped, #{b.trimmed} trimmed; " <>
            "after: #{a.dropped} dropped, #{a.trimmed} trimmed): totals and findings may be incomplete."
      ],
      & &1
    )
  end

  defp tally_change(before, after_) do
    b = Map.take(before, [:count, :total_us])
    a = Map.take(after_, [:count, :total_us])
    %{before: b, after: a, delta: %{count: a.count - b.count, total_us: a.total_us - b.total_us}}
  end

  defp n_plus_one_key(group), do: {group.sql, without_line(group.origin)}

  defp error_key(error),
    do: {error.source, without_line(Map.get(error, :origin)), normalize_message(error.message)}

  # "lib/app.ex:10: App.list/0" -> "lib/app.ex: App.list/0"
  defp without_line(origin) when is_binary(origin),
    do: Regex.replace(~r/\A(.*?):\d+: /, origin, "\\1: ")

  defp without_line(origin), do: origin

  # The first line, with pids, references, ports and numbers made equal.
  defp normalize_message(message) when is_binary(message) do
    message
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.replace(~r/#(PID|Reference|Port)<[^>]*>/, "#\\1")
    |> String.replace(~r/\d+/, "N")
  end

  defp normalize_message(message), do: inspect(message, limit: 5)

  # Distinct keys only, each with its number of occurrences (`count` on errors).
  defp group(items, key) do
    counts = Enum.frequencies_by(items, key)
    items |> Enum.uniq_by(key) |> Enum.map(&{key.(&1), &1, Map.fetch!(counts, key.(&1))})
  end

  defp diff(before, after_, key) do
    before_groups = group(before, key)
    after_groups = group(after_, key)
    before_keys = MapSet.new(before_groups, &elem(&1, 0))
    after_keys = MapSet.new(after_groups, &elem(&1, 0))

    {for({k, item, n} <- before_groups, k not in after_keys, do: counted(item, n)),
     for({k, item, n} <- after_groups, k not in before_keys, do: counted(item, n)),
     MapSet.size(MapSet.intersection(before_keys, after_keys))}
  end

  # N+1 groups carry their own `count`; errors get the number of occurrences.
  defp counted(%{callbacks: _} = group, _n), do: group
  defp counted(error, n), do: Map.put(error, :count, n)

  defp with_totals(fixed, new, still) do
    %{
      fixed: Enum.take(fixed, @cap),
      fixed_total: length(fixed),
      new: Enum.take(new, @cap),
      new_total: length(new),
      still: still
    }
  end
end
