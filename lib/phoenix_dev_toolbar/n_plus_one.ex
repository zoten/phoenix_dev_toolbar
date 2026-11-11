defmodule PhoenixDevToolbar.NPlusOne do
  @moduledoc false
  # The N+1 detector (ADR 08), pure and folded event by event in the panel: the
  # same SQL from the same origin repeated `threshold` times in one callback
  # span of one session (ADR 02) is an N+1. Without `stacktrace: true` the
  # origin is unknown and the SQL alone is the key.
  #
  # A group is one SQL and origin, wherever it happens again: the dead render
  # and the connected mount, or every click, add a callback to the same group.
  # A `:n_plus_one_cleared` event (the Ecto tab's Clear button) starts over.
  #
  # Bounded: counts are kept for the last @spans_per_sid spans of each sid
  # (processes of one sid, nested LiveViews, interleave their spans), at most
  # @max_keys distinct queries per span, keyed by a hash of SQL and origin;
  # groups are capped at @max_groups, most recent first, while `detected` keeps
  # the true number of distinct groups. Each group keeps its last
  # @spans_per_group callback spans (`spans`, newest first) with the count
  # reached in each, so a reader can name the callbacks (Report, ADR 13).
  #
  # The origin is the first stacktrace frame outside Ecto, DBConnection and the
  # repo: for queries run by Ecto's own tasks (parallel preloads) it is a weak
  # one (a Task or Enum frame).

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.NPlusOne

  @max_keys 500
  @max_groups 50
  @spans_per_sid 4
  @sids_per_group 4
  @spans_per_group 10

  defstruct threshold: 5, spans: %{}, groups: [], detected: 0

  @type group :: %{
          key: integer(),
          sql: String.t() | nil,
          origin: String.t() | nil,
          count: pos_integer(),
          callbacks: pos_integer(),
          sids: [String.t()],
          seq: pos_integer() | nil,
          at: integer() | nil,
          spans: [span_count()]
        }
  @type span_count :: %{
          sid: String.t(),
          span: non_neg_integer() | nil,
          caller?: boolean(),
          count: pos_integer()
        }
  @type t :: %NPlusOne{
          threshold: pos_integer() | false,
          spans: %{String.t() => [{non_neg_integer() | nil, %{integer() => pos_integer()}}]},
          groups: [group()],
          detected: non_neg_integer()
        }

  @doc "A detector flagging `threshold` repetitions, or a disabled one (`false`)."
  @spec new(pos_integer() | false) :: t()
  def new(threshold) when (is_integer(threshold) and threshold >= 2) or threshold == false,
    do: %NPlusOne{threshold: threshold}

  @doc """
  Folds an event. A query returns `:detected` when it reaches the threshold in
  its callback, `:repeated` past it, `:ok` otherwise. A `:n_plus_one_cleared`
  event starts over; anything else changes nothing.
  """
  @spec add(t(), Event.t()) :: {t(), :ok | :detected | :repeated}
  def add(%NPlusOne{threshold: threshold}, %Event{kind: :n_plus_one_cleared}),
    do: {new(threshold), :ok}

  def add(%NPlusOne{threshold: false} = state, _event), do: {state, :ok}

  def add(%NPlusOne{} = state, %Event{kind: :query, sid: sid, span: span} = event) do
    key = :erlang.phash2(key(event))
    counts = counts_in(state, sid, span)

    case counts do
      %{^key => count} ->
        bump(state, event, sid, span, Map.put(counts, key, count + 1), count + 1)

      _new when map_size(counts) >= @max_keys ->
        {state, :ok}

      _new ->
        bump(state, event, sid, span, Map.put(counts, key, 1), 1)
    end
  end

  def add(state, _event), do: {state, :ok}

  @doc "The detected groups, most recent first (at most 50)."
  @spec groups(t()) :: [group()]
  def groups(%NPlusOne{groups: groups}), do: groups

  @doc "How many distinct groups were detected (since the last clear)."
  @spec detected(t()) :: non_neg_integer()
  def detected(%NPlusOne{detected: detected}), do: detected

  @doc "The group key of a query event: a hash of its SQL and origin."
  @spec group_key(Event.t()) :: integer()
  def group_key(%Event{} = event), do: :erlang.phash2(key(event))

  defp key(%Event{data: data}), do: {data[:sql], origin(data)}

  defp origin(%{stacktrace: [first | _]}), do: first
  defp origin(%{initial_call: initial_call}) when is_binary(initial_call), do: initial_call
  defp origin(_data), do: nil

  defp counts_in(%NPlusOne{spans: spans}, sid, span) do
    case List.keyfind(Map.get(spans, sid, []), span, 0) do
      {^span, counts} -> counts
      nil -> %{}
    end
  end

  # The span moves to the front; the oldest of a sid's spans is dropped.
  defp bump(state, event, sid, span, counts, count) do
    recent = [{span, counts} | List.keydelete(Map.get(state.spans, sid, []), span, 0)]
    state = %{state | spans: Map.put(state.spans, sid, Enum.take(recent, @spans_per_sid))}

    cond do
      count == state.threshold -> {detect(state, event, count), :detected}
      count > state.threshold -> {grow(state, event, count), :repeated}
      true -> {state, :ok}
    end
  end

  # A group seen again (another callback) moves to the front.
  defp detect(state, %Event{sid: sid, seq: seq, at: at} = event, count) do
    {sql, origin} = key(event)
    key = :erlang.phash2({sql, origin})
    span = span_count(event, count)

    case Enum.split_with(state.groups, &(&1.key == key)) do
      {[group], others} ->
        group = %{
          group
          | count: max(group.count, count),
            callbacks: group.callbacks + 1,
            sids: Enum.take(Enum.uniq([sid | group.sids]), @sids_per_group),
            at: at,
            spans: Enum.take([span | group.spans], @spans_per_group)
        }

        %{state | groups: [group | others]}

      {[], groups} ->
        group = %{
          key: key,
          sql: sql,
          origin: origin,
          count: count,
          callbacks: 1,
          sids: [sid],
          seq: seq,
          at: at,
          spans: [span]
        }

        %{state | groups: Enum.take([group | groups], @max_groups), detected: state.detected + 1}
    end
  end

  defp grow(state, %Event{sid: sid, span: span} = event, count) do
    key = :erlang.phash2(key(event))

    groups =
      Enum.map(state.groups, fn
        %{key: ^key} = group ->
          %{
            group
            | count: max(group.count, count),
              spans: grow_span(group.spans, sid, span, count)
          }

        group ->
          group
      end)

    %{state | groups: groups}
  end

  defp grow_span(spans, sid, span, count) do
    Enum.map(spans, fn
      %{sid: ^sid, span: ^span} = entry -> %{entry | count: count}
      entry -> entry
    end)
  end

  defp span_count(%Event{sid: sid, span: span, data: data}, count),
    do: %{sid: sid, span: span, caller?: data[:caller?] == true, count: count}
end
