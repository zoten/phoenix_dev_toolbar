defmodule PhoenixDevToolbar.Summary do
  @moduledoc false
  # Badge figures for the collapsed toolbar, folded incrementally from events
  # so the panel never rescans the whole page on updates.

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Summary

  defstruct queries: 0, db_us: 0, slowest_query_us: 0, failed_queries: 0, response: nil, errors: 0

  @type t :: %Summary{
          queries: non_neg_integer(),
          db_us: non_neg_integer(),
          slowest_query_us: non_neg_integer(),
          failed_queries: non_neg_integer(),
          response: %{status: integer() | nil, duration: non_neg_integer() | nil} | nil,
          errors: non_neg_integer()
        }

  @spec new([Event.t()]) :: t()
  def new(events \\ []), do: Enum.reduce(events, %Summary{}, &add(&2, &1))

  @doc """
  Folds one event into the summary.

      iex> alias PhoenixDevToolbar.{Event, Summary}
      iex> query = Event.new(:ecto, :query, %{result: {:ok, 1}}, at: 0)
      iex> summary = Summary.new([%{query | duration: 1200}, %{query | duration: 300}])
      iex> {summary.queries, summary.db_us, summary.slowest_query_us}
      {2, 1500, 1200}

  """
  @spec add(t(), Event.t()) :: t()
  def add(%Summary{} = summary, %Event{
        plugin: :ecto,
        kind: :query,
        duration: duration,
        data: data
      }) do
    duration = duration || 0

    %{
      summary
      | queries: summary.queries + 1,
        db_us: summary.db_us + duration,
        slowest_query_us: max(summary.slowest_query_us, duration),
        failed_queries: summary.failed_queries + failed(data)
    }
  end

  def add(%Summary{} = summary, %Event{
        plugin: :request,
        kind: :response,
        duration: duration,
        data: data
      }),
      do: %{summary | response: %{status: data[:status], duration: duration}}

  def add(%Summary{} = summary, %Event{plugin: :request, kind: :exception}),
    do: %{summary | errors: summary.errors + 1}

  def add(%Summary{} = summary, %Event{}), do: summary

  defp failed(%{result: {:error, _}}), do: 1
  defp failed(_data), do: 0
end
