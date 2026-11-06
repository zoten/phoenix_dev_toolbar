defmodule PhoenixDevToolbar.NPlusOne do
  @moduledoc false
  # The N+1 detector (ADR 08), pure and folded event by event in the panel: the
  # same SQL from the same origin repeated `threshold` times in one callback
  # span of one session (ADR 02) is an N+1. Without `stacktrace: true` the
  # origin is unknown and the SQL alone is the key.
  #
  # Bounded: counts are kept for the current span of each sid only, at most
  # @max_keys distinct queries per span; detected groups are capped at
  # @max_groups, newest first, while `detected` keeps the true total.

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.NPlusOne

  @max_keys 500
  @max_groups 50

  defstruct threshold: 5, spans: %{}, groups: [], detected: 0

  @type group :: %{
          sid: String.t(),
          span: non_neg_integer() | nil,
          sql: String.t() | nil,
          origin: String.t() | nil,
          count: pos_integer(),
          seq: pos_integer() | nil
        }
  @type t :: %NPlusOne{
          threshold: pos_integer() | false,
          spans: %{String.t() => {non_neg_integer() | nil, %{term() => pos_integer()}}},
          groups: [group()],
          detected: non_neg_integer()
        }

  @doc "A detector flagging `threshold` repetitions, or a disabled one (`false`)."
  @spec new(pos_integer() | false) :: t()
  def new(threshold) when (is_integer(threshold) and threshold >= 2) or threshold == false,
    do: %NPlusOne{threshold: threshold}

  @doc """
  Folds a query event. Returns `:detected` when its group reaches the threshold,
  `:repeated` past it, `:ok` otherwise (and for anything that is not a query).
  """
  @spec add(t(), Event.t()) :: {t(), :ok | :detected | :repeated}
  def add(%NPlusOne{threshold: false} = state, _event), do: {state, :ok}

  def add(%NPlusOne{} = state, %Event{kind: :query, sid: sid, span: span} = event) do
    key = key(event)
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

  @doc "The detected groups, newest first (at most #{@max_groups})."
  @spec groups(t()) :: [group()]
  def groups(%NPlusOne{groups: groups}), do: groups

  @doc "How many groups were detected in total."
  @spec detected(t()) :: non_neg_integer()
  def detected(%NPlusOne{detected: detected}), do: detected

  defp key(%Event{data: data}), do: {data[:sql], origin(data)}

  defp origin(%{stacktrace: [first | _]}), do: first
  defp origin(_data), do: nil

  # A new span of a sid drops the counts of its previous span.
  defp counts_in(%NPlusOne{spans: spans}, sid, span) do
    case spans do
      %{^sid => {^span, counts}} -> counts
      _other -> %{}
    end
  end

  defp bump(state, event, sid, span, counts, count) do
    state = %{state | spans: Map.put(state.spans, sid, {span, counts})}

    cond do
      count == state.threshold -> {detect(state, event, count), :detected}
      count > state.threshold -> {grow(state, event, count), :repeated}
      true -> {state, :ok}
    end
  end

  defp detect(state, %Event{sid: sid, span: span, seq: seq} = event, count) do
    {sql, origin} = key(event)
    group = %{sid: sid, span: span, sql: sql, origin: origin, count: count, seq: seq}

    %{
      state
      | groups: Enum.take([group | state.groups], @max_groups),
        detected: state.detected + 1
    }
  end

  defp grow(state, %Event{sid: sid, span: span} = event, count) do
    {sql, origin} = key(event)

    groups =
      Enum.map(state.groups, fn
        %{sid: ^sid, span: ^span, sql: ^sql, origin: ^origin} = group -> %{group | count: count}
        group -> group
      end)

    %{state | groups: groups}
  end
end
