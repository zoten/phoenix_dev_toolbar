defmodule PhoenixDevToolbar.Page do
  @moduledoc false
  # Which sessions make up the page a panel shows (ADR 02, ADR 04).
  #
  # The panel is opened with the dead render's request sid. Its LiveView child
  # (connected mount) joins the page; live navigation replaces it, following
  # children of the same transport, so a duplicated tab never hijacks the panel.
  #
  #   request ─▶ LiveView                          shows [request, LiveView]
  #   request ─▶ LiveView ─▶ LiveView (navigated)  shows [newest LiveView]

  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @spec sids(Session.sid()) :: [Session.sid()]
  def sids(root) do
    case Store.session(root) do
      {:ok, %Session{}} -> follow(root, Store.sessions())
      :error -> []
    end
  end

  defp follow(root, sessions) do
    case latest_child(sessions, root, :any) do
      nil ->
        [root]

      %Session{} = first ->
        case newest_descendant(sessions, first) do
          ^first -> [root, first.sid]
          %Session{sid: sid} -> [sid]
        end
    end
  end

  defp newest_descendant(sessions, %Session{sid: sid, transport: transport} = current) do
    case latest_child(sessions, sid, transport) do
      nil -> current
      child -> newest_descendant(sessions, child)
    end
  end

  # Sticky LiveViews have no transport (Tracker), so they never match a tab.
  defp latest_child(sessions, parent, transport) do
    sessions
    |> Enum.filter(
      &(&1.kind == :live_view and &1.parent == parent and
          (transport == :any or (is_pid(transport) and &1.transport == transport)))
    )
    |> Enum.max_by(& &1.started_at, fn -> nil end)
  end
end
