defmodule PhoenixDevToolbar.Tracker do
  @moduledoc false
  # Turns LiveView mounts into sessions (ADR 02). Runs inside the host process
  # on `[:phoenix, :live_view, :mount, :start]`, before any plugin sees the event.
  #
  #   dead render (request process)    index socket.id -> request sid
  #   connected mount after it         new LiveView session, parent = request sid
  #   live navigation                  new session, parent = previous LiveView session
  #   reconnect or crash rejoin        claim the existing LiveView session
  #   nested LiveView                  share the parent LiveView's sid
  #
  # LiveView keeps the same socket.id across live navigation (the client clones
  # the main element and rejoins with its session token, the server only swaps
  # the view), so the id alone cannot tell navigation from reconnect. A rejoin
  # is a mount of the same view and path whose previous owner is gone.

  alias Phoenix.LiveView.Socket
  alias PhoenixDevToolbar.Attribution
  alias PhoenixDevToolbar.Label
  alias PhoenixDevToolbar.LiveViewCompat
  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @spec live_view_mount(Socket.t(), String.t() | nil) :: :ok
  def live_view_mount(%Socket{} = socket, uri) do
    info = LiveViewCompat.info(socket)

    case own_view?(info.view) do
      true -> :ok
      false -> track(info, uri, Attribution.tracked_sid())
    end
  end

  # Dead render: the plug already tracked the request process.
  defp track(%{connected?: false}, _uri, nil), do: :ok
  defp track(%{connected?: false, id: id}, _uri, sid), do: link(id, sid)

  # A LiveView process mounts once: an already tracked process is a no-op.
  defp track(%{connected?: true} = info, uri, nil), do: connected(info, uri)
  defp track(%{connected?: true}, _uri, _sid), do: :ok

  defp connected(info, uri) do
    path = path(uri)

    case resolve(info, path) do
      :ignore ->
        :ok

      {:share, sid} ->
        adopt(info, sid)

      {:reuse, sid} ->
        with {:ok, session} <- Store.claim(sid, self(), tab_transport(info)) do
          adopt(info, sid)
          Notify.session(session)
        end

        :ok

      {:new, parent} ->
        session =
          Session.new(:live_view,
            parent: parent,
            label: Label.parent_label(parent),
            owner: self(),
            transport: tab_transport(info),
            view: info.view,
            path: path
          )

        _ = Store.new_session(session)
        adopt(info, session.sid)
        Notify.session(session)
    end
  end

  defp resolve(%{parent: parent, sticky?: false}, _path) when is_pid(parent) do
    case Store.sid_for_pid(parent) do
      nil -> :ignore
      sid -> {:share, sid}
    end
  end

  defp resolve(%{id: id, transport: transport} = info, path) do
    with sid when is_binary(sid) <- Store.sid_for_socket_id(id),
         {:ok, %Session{} = session} <- Store.session(sid) do
      classify(session, info, path)
    else
      _ -> {:new, Store.latest_for_transport(transport)}
    end
  end

  defp classify(%Session{kind: :request, sid: sid}, _info, _path), do: {:new, sid}

  defp classify(%Session{kind: :live_view, sid: sid} = session, info, path) do
    case rejoin?(session, info, path) do
      true -> {:reuse, sid}
      false -> {:new, sid}
    end
  end

  defp rejoin?(%Session{owner: owner, view: view, path: path}, %{view: view}, path),
    do: not alive?(owner)

  defp rejoin?(_session, _info, _path), do: false

  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive?(_pid), do: false

  # Sticky LiveViews outlive navigation: never the "latest" session of a tab.
  defp tab_transport(%{sticky?: true}), do: nil
  defp tab_transport(%{transport: transport}), do: transport

  defp adopt(info, sid) do
    Attribution.track(sid)
    link(info.id, sid)
  end

  defp link(socket_id, sid) do
    Store.link_socket_id(socket_id, sid)
    :ok
  end

  defp own_view?(view), do: String.starts_with?(Atom.to_string(view), "Elixir.PhoenixDevToolbar.")

  defp path(nil), do: nil
  defp path(uri) when is_binary(uri), do: URI.parse(uri).path
end
