defmodule PhoenixDevToolbar.LiveViewCompat do
  @moduledoc false
  # The only module allowed to look inside `Phoenix.LiveView.Socket` (ADR 02).
  # Verified against LiveView 1.1 and 1.2; covered by the CI version matrix.

  require Logger

  alias Phoenix.LiveView.Socket
  alias PhoenixDevToolbar.LiveViewCompat
  alias PhoenixDevToolbar.Truncate

  @push_names 10
  @name_bytes 128
  @warned {LiveViewCompat, :warned, :push_events}

  @type info :: %{
          id: String.t(),
          view: module(),
          connected?: boolean(),
          transport: pid() | nil,
          parent: pid() | nil,
          sticky?: boolean()
        }

  @spec info(Socket.t()) :: info()
  def info(%Socket{} = socket) do
    %{
      id: socket.id,
      view: socket.view,
      connected?: Phoenix.LiveView.connected?(socket),
      transport: socket.transport_pid,
      parent: socket.parent_pid,
      # The channel copies the client's "sticky" join param as is: nil for
      # clients that do not send it (Phoenix.LiveViewTest), so normalise.
      sticky?: socket.sticky? == true
    }
  end

  @doc """
  Keys assigned since the last render, from `socket.assigns.__changed__`, or
  `:all` when change tracking is off. Never reads the values: they can hold the
  previous value of nested maps.
  """
  @spec changed_keys(Socket.t()) :: [atom()] | :all
  def changed_keys(%Socket{assigns: %{__changed__: changed}}) when is_map(changed),
    do: Map.keys(changed)

  def changed_keys(%Socket{}), do: :all

  @doc """
  Names of the events pushed with `Phoenix.LiveView.push_event/4` and not yet
  sent, in push order: at most #{@push_names}, each at most #{@name_bytes} bytes.
  Payloads are never read.

  Reads `socket.private.live_temp[:push_events]` (`[name, payload]` or
  `[name, payload, true]`, newest first), private to LiveView. Any other shape
  returns `:unavailable` and logs one warning per node, so a LiveView upgrade
  degrades the event log instead of breaking it.
  """
  @spec push_event_names(Socket.t()) :: {:ok, [String.t()]} | :unavailable
  def push_event_names(%Socket{private: %{live_temp: %{} = temp}}) do
    case Map.get(temp, :push_events) do
      nil -> {:ok, []}
      events when is_list(events) -> events |> newest(@push_names) |> names([])
      _other -> unavailable()
    end
  end

  def push_event_names(%Socket{}), do: unavailable()

  # The list is newest first: the first @push_names are the last pushed. Walking
  # them prepends, so the result is in push order.
  defp newest(events, n) do
    case proper_take(events, n, []) do
      {:ok, taken} -> taken
      :improper -> :improper
    end
  end

  defp proper_take(_rest, 0, acc), do: {:ok, Enum.reverse(acc)}
  defp proper_take([], _n, acc), do: {:ok, Enum.reverse(acc)}
  defp proper_take([event | rest], n, acc), do: proper_take(rest, n - 1, [event | acc])
  defp proper_take(_improper, _n, _acc), do: :improper

  defp names(:improper, _acc), do: unavailable()
  defp names([], acc), do: {:ok, acc}
  defp names([[name | _payload] | rest], acc), do: names(rest, [name(name) | acc])
  defp names(_improper, _acc), do: unavailable()

  defp name(name) when is_binary(name), do: Truncate.string(name, @name_bytes)
  defp name(name), do: name |> Truncate.inspect_value(limit: 5, printable_limit: 64) |> name()

  defp unavailable do
    case :persistent_term.get(@warned, false) do
      true ->
        :unavailable

      false ->
        :persistent_term.put(@warned, true)

        Logger.warning(
          "[phoenix_dev_toolbar] push_event names unavailable: phoenix_live_view " <>
            "#{Application.spec(:phoenix_live_view, :vsn)} changed socket.private.live_temp"
        )

        :unavailable
    end
  end

  @doc false
  @spec reset_warnings() :: :ok
  def reset_warnings do
    _ = :persistent_term.erase(@warned)
    :ok
  end
end
