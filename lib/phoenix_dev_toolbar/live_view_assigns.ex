defmodule PhoenixDevToolbar.LiveViewAssigns do
  @moduledoc false
  # The one way the toolbar reads a host LiveView's assigns (ADR 07, 15): the
  # panel's snapshot and MCP `page_assigns_shape` both go through `fetch/1`.
  #
  # `Phoenix.LiveView.Debug.socket/1` is a GenServer.call to the host LiveView
  # that copies its whole socket into the caller. Callers run it in a task of
  # their own (never in the LiveView, never in a request or panel process that
  # must stay responsive), and bound what they keep.

  alias PhoenixDevToolbar.Page
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @doc """
  The assigns of the LiveView process `pid`, or `:error` when it is gone, busy
  past the GenServer timeout, or not a LiveView. Never raises.
  """
  @spec fetch(pid()) :: {:ok, map()} | :error
  def fetch(pid) when is_pid(pid) do
    case Phoenix.LiveView.Debug.socket(pid) do
      {:ok, %{assigns: assigns}} when is_map(assigns) -> {:ok, assigns}
      _other -> :error
    end
  end

  @doc """
  The page's newest LiveView owner pid (read now: a rejoin changes the owner),
  or nil. A request page resolves to its connected mount's LiveView.
  """
  @spec owner(Page.t()) :: pid() | nil
  def owner(%Page{} = page) do
    case session(page) do
      %Session{owner: owner} -> owner
      nil -> nil
    end
  end

  @doc "The session of the page's newest LiveView (with an owner pid), or nil."
  @spec session(Page.t()) :: Session.t() | nil
  def session(%Page{sids: sids}) do
    sids
    |> Enum.reverse()
    |> Enum.find_value(&live_view_session/1)
  end

  defp live_view_session(sid) do
    case safe_session(sid) do
      {:ok, %Session{kind: :live_view, owner: owner} = session} when is_pid(owner) -> session
      _other -> nil
    end
  end

  # The Store's tables vanish while it restarts.
  defp safe_session(sid) do
    Store.session(sid)
  rescue
    ArgumentError -> :error
  end
end
