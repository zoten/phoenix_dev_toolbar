defmodule PhoenixDevToolbar.Attribution do
  @moduledoc false
  # Which session does the current process belong to (ADR 02)? Called by every
  # telemetry handler, so the untracked path must stay a single pdict read for
  # processes without `$callers`.

  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @key :pdt_sid

  @spec current() :: {Session.sid(), :self | :caller} | nil
  def current do
    case Process.get(@key) do
      nil -> from_callers(Process.get(:"$callers"))
      sid -> {sid, :self}
    end
  end

  @doc "Marks the current process as part of `sid`, for itself and its `$callers` children."
  @spec track(Session.sid()) :: :ok
  # Index first, then mark: a failure (Store tables missing while it restarts)
  # leaves the process unmarked rather than half tracked.
  def track(sid) do
    Store.track_pid(self(), sid)
    Process.put(@key, sid)
    :ok
  rescue
    ArgumentError -> untrack()
  end

  @doc "Removes the mark set by `track/1` from the current process."
  @spec untrack() :: :ok
  def untrack do
    _ = Process.delete(@key)
    forget_pid()
  end

  @doc """
  Drops the `$callers` index row of the current process but keeps its mark:
  a finished request's sid must not leak to processes spawned later by the same
  connection process (a websocket upgrade on a keep-alive connection).
  """
  @spec forget_pid() :: :ok
  def forget_pid do
    Store.untrack_pid(self())
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec tracked_sid() :: Session.sid() | nil
  def tracked_sid, do: Process.get(@key)

  defp from_callers(nil), do: nil
  defp from_callers([]), do: nil

  defp from_callers([pid | rest]) when is_pid(pid) do
    case Store.sid_for_pid(pid) do
      nil -> from_callers(rest)
      sid -> {sid, :caller}
    end
  end

  defp from_callers([_name | rest]), do: from_callers(rest)
end
