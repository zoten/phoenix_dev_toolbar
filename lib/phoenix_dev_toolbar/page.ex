defmodule PhoenixDevToolbar.Page do
  @moduledoc false
  # Which sessions make up the page a panel shows (ADR 02, ADR 04).
  #
  # The panel is opened with the dead render's request sid (the root). At mount
  # the page is derived once from the Store (`initial/1`); after that it only
  # moves forward one `{:pdt_session, sid}` notification at a time (`follow/2`),
  # so expiring older sessions (the root after its TTL, a LiveView we navigated
  # away from) never breaks the panel.
  #
  #   request ─▶ LiveView                          shows [request, LiveView]
  #   request ─▶ LiveView ─▶ LiveView (navigated)  shows [newest LiveView]
  #
  # A child of the current LiveView is navigation when it shares the transport
  # (one websocket per browser tab) or goes to another path. A duplicated tab
  # rejoins the same socket id on another transport at the same path, so it
  # never hijacks the panel; a navigation across a reconnect is still followed.

  alias PhoenixDevToolbar.Page
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  defstruct root: nil, sids: [], transport: nil, path: nil, owner: nil

  @type t :: %Page{
          root: Session.sid(),
          sids: [Session.sid()],
          transport: pid() | nil,
          path: String.t() | nil,
          owner: pid() | nil
        }
  @type change :: :connected | :navigated | :rejoined

  @doc "Derives the page from the Store; `sids` is empty when the root is gone."
  @spec initial(Session.sid()) :: t()
  def initial(root) do
    case Store.session(root) do
      {:ok, %Session{}} -> descend(%Page{root: root, sids: [root]}, Store.sessions())
      :error -> %Page{root: root}
    end
  end

  @doc """
  Moves the page forward for a newly announced session, or `:ignore`s it.

    * `:connected` - the first LiveView of the request joined
    * `:navigated` - live navigation in the same tab replaced the LiveView
    * `:rejoined`  - the current LiveView reconnected (maybe on a new transport)
  """
  @spec follow(t(), Session.t()) :: {change(), t()} | :ignore
  def follow(%Page{} = page, %Session{kind: :live_view, sid: sid} = child) do
    cond do
      sid in page.sids -> {:rejoined, %{page | transport: child.transport, owner: child.owner}}
      connected?(page, child) -> {:connected, %{at(page, child) | sids: [page.root, sid]}}
      navigated?(page, child) -> {:navigated, %{at(page, child) | sids: [sid]}}
      true -> :ignore
    end
  end

  def follow(%Page{}, %Session{}), do: :ignore

  # `owner` changes on every LiveView change, rejoins included: tabs reading
  # from the LiveView restart their reads (Panel props).
  defp at(page, %Session{transport: transport, path: path, owner: owner}),
    do: %{page | transport: transport, path: path, owner: owner}

  defp connected?(%Page{root: root, sids: [root]}, %Session{parent: root}), do: true
  defp connected?(_page, _child), do: false

  # Sticky LiveViews have no transport (Tracker) and never count as navigation.
  defp navigated?(
         %Page{sids: sids} = page,
         %Session{parent: parent, transport: transport} = child
       )
       when is_pid(transport) do
    parent == List.last(sids) and (transport == page.transport or child.path != page.path)
  end

  defp navigated?(_page, _child), do: false

  # At mount, catch up with whatever happened before the panel opened.
  # Only forward steps: a session already on the page would match `:rejoined`.
  defp descend(page, sessions) do
    case Enum.find_value(newest_first(sessions), &forward(page, &1)) do
      nil -> page
      next -> descend(next, sessions)
    end
  end

  defp forward(page, session) do
    case follow(page, session) do
      {change, next} when change in [:connected, :navigated] -> next
      _ -> nil
    end
  end

  defp newest_first(sessions), do: Enum.sort_by(sessions, & &1.started_at, :desc)
end
