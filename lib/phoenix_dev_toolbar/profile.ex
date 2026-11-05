defmodule PhoenixDevToolbar.Profile do
  @moduledoc false
  # Lifecycle profiler figures for the LiveView tab, folded incrementally from
  # `:live_view` events in the panel process (like PhoenixDevToolbar.Summary),
  # so they survive the Store trimming old events.
  #
  # One row per `{callback, component, event}`; renders are `{:render, component,
  # nil}` (`nil` component: the LiveView itself). Event names come from the
  # client, so the number of rows is capped: past @max_keys, new keys share the
  # `:other` row.

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Profile

  @max_keys 100

  defstruct rows: %{}

  @type key :: {atom(), module() | nil, String.t() | nil} | :other
  @type row :: %{
          key: key(),
          count: non_neg_integer(),
          total_us: non_neg_integer(),
          max_us: non_neg_integer()
        }
  @type t :: %Profile{rows: %{key() => {non_neg_integer(), non_neg_integer(), non_neg_integer()}}}

  @spec new([Event.t()]) :: t()
  def new(events \\ []), do: Enum.reduce(events, %Profile{}, &add(&2, &1))

  @doc """
  Folds one event into the profile.

      iex> alias PhoenixDevToolbar.{Event, Profile}
      iex> event = Event.new(:live_view, :callback, %{callback: :mount, component: nil, event: nil}, at: 0)
      iex> Profile.new([%{event | duration: 120}]) |> Profile.rows()
      [%{key: {:mount, nil, nil}, count: 1, total_us: 120, max_us: 120}]

  """
  @spec add(t(), Event.t()) :: t()
  def add(%Profile{} = profile, %Event{plugin: :live_view, kind: :callback, data: data} = event),
    do: put(profile, {data.callback, data.component, data.event}, 1, event.duration || 0)

  def add(%Profile{} = profile, %Event{plugin: :live_view, kind: :render, data: data} = event),
    do: put(profile, {:render, data.component, nil}, 1, event.duration || 0)

  def add(%Profile{} = profile, %Event{}), do: profile

  @doc "Rows, slowest total first."
  @spec rows(t()) :: [row()]
  def rows(%Profile{rows: rows}) do
    rows
    |> Enum.map(fn {key, {count, total, max}} ->
      %{key: key, count: count, total_us: total, max_us: max}
    end)
    |> Enum.sort_by(& &1.total_us, :desc)
  end

  defp put(%Profile{rows: rows} = profile, key, count, us) do
    key = bounded_key(rows, key)

    rows =
      Map.update(rows, key, {count, us, us}, fn {n, total, max} ->
        {n + count, total + us, max(max, us)}
      end)

    %{profile | rows: rows}
  end

  defp bounded_key(rows, key) when is_map_key(rows, key), do: key
  defp bounded_key(rows, _key) when map_size(rows) >= @max_keys, do: :other
  defp bounded_key(_rows, key), do: key
end
