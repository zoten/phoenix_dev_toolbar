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
  def track(sid) do
    Process.put(@key, sid)
    Store.track_pid(self(), sid)
    :ok
  end

  @doc "Removes the mark set by `track/1` from the current process."
  @spec untrack() :: :ok
  def untrack do
    _ = Process.delete(@key)
    Store.untrack_pid(self())
    :ok
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
