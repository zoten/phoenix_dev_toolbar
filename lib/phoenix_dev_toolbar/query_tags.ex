defmodule PhoenixDevToolbar.QueryTags do
  @moduledoc false
  # The Ecto tab's filter tags (ADR 08): a query is tagged with its source table
  # (or "no source"), "framework" when it is framework noise and "task" when a
  # Task.async child ran it. Keys are strings built from Store data, prefixed so
  # a table named "framework" never collides with the flag; never atoms.

  alias PhoenixDevToolbar.QueryFrames

  @no_source "flag:no_source"
  @framework "flag:framework"
  @task "flag:task"
  @flags [@no_source, @framework, @task]

  @type tag :: String.t()

  @doc "The filter tags of a query event's data."
  @spec tags(map()) :: [tag()]
  def tags(%{} = data) do
    [
      source_tag(data[:source]),
      QueryFrames.noise(data) != nil and @framework,
      data[:caller?] == true and @task
    ]
    |> Enum.filter(&is_binary/1)
  end

  @doc "Whether a query with these data is shown when the tags in `hidden` are off."
  @spec visible?(map(), MapSet.t(tag())) :: boolean()
  def visible?(data, hidden) do
    MapSet.size(hidden) == 0 or not Enum.any?(tags(data), &MapSet.member?(hidden, &1))
  end

  @doc "Turns `tag` off when it is on, on when it is off."
  @spec toggle(MapSet.t(tag()), tag()) :: MapSet.t(tag())
  def toggle(hidden, tag) do
    case MapSet.member?(hidden, tag) do
      true -> MapSet.delete(hidden, tag)
      false -> MapSet.put(hidden, tag)
    end
  end

  @doc "Turns every tag of `tags` off."
  @spec hide(MapSet.t(tag()), [tag()]) :: MapSet.t(tag())
  def hide(hidden, tags), do: Enum.into(tags, hidden)

  @doc "Adds a query's tags to `counts` (tag => number of queries)."
  @spec count(%{tag() => pos_integer()}, map()) :: %{tag() => pos_integer()}
  def count(counts, data),
    do: Enum.reduce(tags(data), counts, &Map.update(&2, &1, 1, fn n -> n + 1 end))

  @doc """
  The tags of `counts` in display order: source tables sorted, then the flags.
  At most `limit` sources; the rest are reported as a number.
  """
  @spec ordered(%{tag() => pos_integer()}, pos_integer()) ::
          {[{tag(), String.t(), pos_integer()}], non_neg_integer()}
  def ordered(counts, limit) do
    sources =
      for {"source:" <> name = tag, n} <- counts, do: {tag, name, n}

    {shown, rest} = sources |> Enum.sort_by(&elem(&1, 1)) |> Enum.split(limit)
    flags = for tag <- @flags, n = counts[tag], do: {tag, label(tag), n}
    {shown ++ flags, length(rest)}
  end

  defp label(@no_source), do: "no source"
  defp label(@framework), do: "framework"
  defp label(@task), do: "task"

  defp source_tag(source) when is_binary(source) and source != "", do: "source:" <> source
  defp source_tag(_none), do: @no_source
end
