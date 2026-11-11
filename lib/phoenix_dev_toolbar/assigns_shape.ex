defmodule PhoenixDevToolbar.AssignsShape do
  @moduledoc false
  # What a LiveView's assigns weigh, without their values (ADR 15, MCP
  # `page_assigns_shape`). Runs in the caller's process only to wait: the socket
  # copy and the `:erts_debug.flat_size/1` walks happen in a task that is killed
  # at the timeout, never in the LiveView.
  #
  # Cost: `Debug.socket/1` copies the LiveView's assigns into the task, so a
  # large assign is briefly held twice (once there, once here) while it is read.

  alias Phoenix.LiveView.LiveStream
  alias PhoenixDevToolbar.LiveViewAssigns
  alias PhoenixDevToolbar.LiveViewCompat
  alias PhoenixDevToolbar.Page

  @timeout_ms 2_000
  @max_entries 100
  @max_key 100

  @type entry :: %{
          key: String.t(),
          type: String.t(),
          length: non_neg_integer() | nil,
          words: non_neg_integer(),
          stream?: boolean()
        }
  @type shape :: %{
          view: String.t() | nil,
          total_words: non_neg_integer(),
          omitted: non_neg_integer(),
          live_view_sid: String.t(),
          live_view_path: String.t() | nil,
          assigns: [entry()]
        }
  @type error :: :no_live_view | :gone | :timeout

  @doc """
  The shape of the LiveView of the page `sid`. `{:error, :no_live_view}` for a
  page without a connected LiveView, `:gone` when it died or did not answer as a
  LiveView, `:timeout` when it took longer than the timeout. Never raises.
  """
  @spec read(String.t(), pos_integer()) :: {:ok, shape()} | {:error, error()}
  def read(sid, timeout \\ @timeout_ms) do
    case live_view(sid) do
      nil ->
        {:error, :no_live_view}

      %{owner: owner} = session ->
        with {:ok, shape} <- read_owner(owner, timeout) do
          {:ok, Map.merge(shape, %{live_view_sid: session.sid, live_view_path: session.path})}
        end
    end
  end

  # Page.initial follows live navigation: this may be a later LiveView than the
  # page's path says, so the result names it.
  defp live_view(sid) do
    sid |> Page.initial() |> LiveViewAssigns.session()
  rescue
    ArgumentError -> nil
  end

  defp read_owner(owner, timeout) do
    task = Task.async(fn -> compute(owner) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :gone}
      nil -> {:error, :timeout}
    end
  end

  # The task body never raises into the linked caller.
  defp compute(owner) do
    case LiveViewAssigns.fetch(owner) do
      {:ok, assigns} -> {:ok, shape(owner, assigns)}
      :error -> {:error, :gone}
    end
  rescue
    _exception -> {:error, :gone}
  catch
    _kind, _reason -> {:error, :gone}
  end

  defp shape(owner, assigns) do
    entries =
      assigns
      |> Map.delete(:__changed__)
      |> Enum.flat_map(&entries/1)
      |> Enum.sort_by(& &1.words, :desc)

    %{
      view: view(owner),
      total_words: entries |> Enum.map(& &1.words) |> Enum.sum(),
      omitted: max(length(entries) - @max_entries, 0),
      assigns: Enum.take(entries, @max_entries)
    }
  end

  defp view(owner) do
    case LiveViewCompat.live_view_label(owner) do
      {:ok, view} -> inspect(view)
      :error -> nil
    end
  end

  # The `streams` assign holds the streams' pending inserts (and bookkeeping):
  # report each stream under its own name with `stream?: true`.
  defp entries({:streams, %{} = streams}) do
    for {name, %LiveStream{} = stream} <- streams, do: entry(name, stream)
  end

  defp entries({key, value}), do: [entry(key, value)]

  defp entry(key, value) do
    %{
      key: key(key),
      type: type(value),
      length: length_of(value),
      words: :erts_debug.flat_size(value),
      stream?: match?(%LiveStream{}, value)
    }
  end

  defp key(key),
    do: key |> inspect(limit: 5, printable_limit: @max_key) |> String.slice(0, @max_key)

  defp type(%{__struct__: module}) when is_atom(module), do: "struct " <> inspect(module)
  defp type(value) when is_list(value), do: "list"
  defp type(value) when is_map(value), do: "map"
  defp type(value) when is_binary(value), do: "binary"
  defp type(value) when is_integer(value), do: "integer"
  defp type(value) when is_atom(value), do: "atom"
  defp type(value) when is_tuple(value), do: "tuple"
  defp type(value) when is_function(value), do: "function"
  defp type(value) when is_pid(value), do: "pid"
  defp type(_value), do: "other"

  defp length_of(%{__struct__: module}) when is_atom(module), do: nil
  defp length_of(value) when is_map(value), do: map_size(value)
  defp length_of(value) when is_list(value), do: proper_length(value, 0)
  defp length_of(_value), do: nil

  # An improper list has no length.
  defp proper_length([], acc), do: acc
  defp proper_length([_head | tail], acc), do: proper_length(tail, acc + 1)
  defp proper_length(_improper, _acc), do: nil
end
