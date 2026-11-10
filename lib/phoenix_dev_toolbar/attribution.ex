defmodule PhoenixDevToolbar.Attribution do
  @moduledoc false
  # Which session does the current process belong to (ADR 02)? Called by every
  # telemetry handler, so the untracked path is two pdict reads (`:pdt_sid`, then
  # `$callers`) and, only for a process with callers, one ETS lookup per caller pid.

  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @key :pdt_sid
  @span_key :pdt_span

  @doc """
  The current process's session, how it is tracked, and its callback span: a
  tracked process's own, or for a `$callers` child the span its caller is in.
  """
  @spec current() :: {Session.sid(), :self | :caller, non_neg_integer()} | nil
  def current do
    case Process.get(@key) do
      nil -> from_callers(Process.get(:"$callers"))
      sid -> {sid, :self, Process.get(@span_key, 0)}
    end
  end

  @doc """
  Starts a new callback span in the current (tracked) process, bumped at each
  LiveView callback start and stop, and published for its `$callers` children.
  Unique across processes: nested LiveViews share their parent's sid.
  """
  @spec next_span() :: non_neg_integer()
  def next_span do
    span = :erlang.unique_integer([:monotonic, :positive])
    Process.put(@span_key, span)
    Store.put_span(self(), span)
    span
  end

  @doc "Marks the current process as part of `sid`, for itself and its `$callers` children."
  @spec track(Session.sid()) :: :ok
  # Index first, then mark: a failure (Store tables missing while it restarts)
  # leaves the process unmarked rather than half tracked.
  def track(sid) do
    # A reused process (keep-alive connection) keeps its current span, so its
    # `$callers` children agree with it.
    Store.track_pid(self(), sid, Process.get(@span_key, 0))
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
    case Store.caller(pid) do
      nil -> from_callers(rest)
      {sid, span} -> {sid, :caller, span}
    end
  end

  defp from_callers([_name | rest]), do: from_callers(rest)
end
