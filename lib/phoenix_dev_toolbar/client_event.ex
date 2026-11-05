defmodule PhoenixDevToolbar.ClientEvent do
  @moduledoc false
  # Client events of the LiveView tab (ADR 07): LiveView's own window events,
  # forwarded by the loader through the PdtPanel hook. The payload is untrusted
  # browser input: only these types and scalar fields are kept, strings capped
  # again, and nothing is stored in ETS.

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Truncate

  @types ~w(phx:page-loading-start phx:page-loading-stop phx:navigate)
  @fields ~w(kind to href patch pop)
  @max_string 260
  # Client timestamps (Date.now(), ms) outside this range are replaced by ours.
  @max_ms 10_000_000_000_000
  # Client events that announce a live navigation arrive just before it resets
  # the log: those received in the last @keep_ms are shown again.
  @keep_ms 2000
  @keep 10

  @type recent :: [{integer(), Event.t()}]

  @doc """
  Builds the `n`th client event of the panel from the hook's payload, or
  `:ignore` when its type is not one the loader listens to.
  """
  @spec build(term(), pos_integer()) :: {:ok, Event.t()} | :ignore
  def build(%{"type" => type} = event, n) when type in @types do
    {:ok, %Event{plugin: :client, kind: :client, at: at(event["at"]), data: data(event, n)}}
  end

  def build(_event, _n), do: :ignore

  @doc "The loader's drop count: only grows, ignores anything but a non negative integer."
  @spec dropped(term(), non_neg_integer()) :: non_neg_integer()
  def dropped(dropped, current) when is_integer(dropped) and dropped >= 0,
    do: max(dropped, current)

  def dropped(_dropped, current), do: current

  @doc "Remembers `event`, received at `now_ms` (monotonic), keeping the last #{@keep}."
  @spec remember(recent(), Event.t(), integer()) :: recent()
  def remember(recent, %Event{} = event, now_ms), do: Enum.take([{now_ms, event} | recent], @keep)

  @doc "The remembered events received in the #{@keep_ms} ms before `now_ms`, oldest first."
  @spec recent(recent(), integer()) :: [Event.t()]
  def recent(recent, now_ms) do
    since = now_ms - @keep_ms
    for {at, event} <- Enum.reverse(recent), at >= since, do: event
  end

  defp data(event, n) do
    fields =
      for field <- @fields,
          value = value(event[field]),
          value != nil,
          do: {field, value}

    %{type: event["type"], fields: fields, n: n}
  end

  defp value(value) when is_binary(value), do: Truncate.string(value, @max_string)
  defp value(value) when is_boolean(value) or is_number(value), do: value
  defp value(_value), do: nil

  # The loader stamps Date.now() (ms); events are stamped in microseconds.
  defp at(ms) when is_integer(ms) and ms > 0 and ms < @max_ms, do: ms * 1000
  defp at(_ms), do: System.system_time(:microsecond)
end
