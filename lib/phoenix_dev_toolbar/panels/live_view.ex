defmodule PhoenixDevToolbar.Panels.LiveView do
  @moduledoc false
  # The LiveView tab (ADR 07), on the public panel API (ADR 05): the profiler
  # and the event log are folded from the plugin's events; the assigns snapshot
  # and the component tree are pulled from the host LiveView through
  # Phoenix.LiveView.Debug, in tasks (start_async), only while someone looks.
  # Client events come from the PdtPanel hook, forwarded by PanelLive.

  use PhoenixDevToolbar.Panel

  alias PhoenixDevToolbar.ClientEvent
  alias PhoenixDevToolbar.ComponentTree
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.LiveViewAssigns
  alias PhoenixDevToolbar.Page
  alias PhoenixDevToolbar.Panel
  alias PhoenixDevToolbar.Panels.LiveView
  alias PhoenixDevToolbar.Panels.LiveViewSections
  alias PhoenixDevToolbar.Profile
  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.Truncate

  # At most one assigns snapshot per second while the Assigns sub-tab is shown.
  @snapshot_ms 1000
  # Component tree poll interval, only while shown, open and visible.
  @tree_ms 2000
  # Rows kept in the DOM; the Store keeps 500 events per plugin and page.
  @dom_limit 500

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(lv_tab: "profiler", profile: Profile.new(), last_changed: [], prev: nil)
     |> assign(snapshot: nil, snapshot_pending?: false, snapshot_at: nil, snapshot_timer: nil)
     |> assign(tree: nil, tree_pending?: false, tree_timer: nil)
     |> assign(client_count: 0, client_dropped: 0, recent_client: [])
     |> stream_configure(:lv_events, dom_id: &dom_id/1)}
  end

  ## Events from the toolbar

  # A new page: start over. The client events that announced a live navigation
  # arrived just before it: they are shown again.
  @impl Panel
  def handle_reset(events, socket) do
    socket
    |> assign(
      profile: Profile.new(events),
      last_changed: Enum.reduce(events, [], &last_changed/2),
      snapshot: nil,
      tree: nil
    )
    |> stream(:lv_events, events, reset: true, limit: -@dom_limit)
    |> reinsert_recent_client()
  end

  # The profile is folded incrementally, never rebuilt from the Store.
  @impl Panel
  def handle_events(events, socket) do
    socket
    |> assign(
      profile: Enum.reduce(events, socket.assigns.profile, &Profile.add(&2, &1)),
      last_changed: Enum.reduce(events, socket.assigns.last_changed, &last_changed/2)
    )
    |> insert_events(events)
    |> snapshot_after(events)
  end

  # The page's LiveView changed (connected, navigated, rejoined), the tab was
  # selected or the panel became visible.
  @impl Panel
  def handle_props(%{assigns: assigns} = socket) do
    prev = assigns.prev || %{page: nil, shown?: false, visible?: false}
    socket = assign(socket, :prev, Map.take(assigns, [:page, :shown?, :visible?]))

    cond do
      prev.page != assigns.page ->
        socket |> drop_reads() |> snapshot_if_shown() |> tree_if_shown()

      not prev.shown? and assigns.shown? ->
        socket |> snapshot_if_shown() |> tree_if_shown()

      not prev.visible? and assigns.visible? ->
        tree_if_shown(socket)

      true ->
        socket
    end
  end

  @impl Panel
  def handle_info(:snapshot, socket),
    do: socket |> assign(:snapshot_timer, nil) |> snapshot_if_shown()

  def handle_info(:tree_poll, socket), do: socket |> assign(:tree_timer, nil) |> poll_tree()

  # From the PdtPanel hook: a client event the loader forwarded (untrusted
  # input). A nil event only updates the drop count.
  def handle_info({:client, %{} = params}, socket) do
    n = socket.assigns.client_count + 1
    dropped = ClientEvent.dropped(params["dropped"], socket.assigns.client_dropped)
    socket = assign(socket, :client_dropped, dropped)

    case ClientEvent.build(params["event"], n) do
      {:ok, client} ->
        recent = ClientEvent.remember(socket.assigns.recent_client, client, now_ms())

        socket
        |> assign(client_count: n, recent_client: recent)
        |> stream_insert(:lv_events, client, limit: -@dom_limit)

      :ignore ->
        socket
    end
  end

  def handle_info(_message, socket), do: socket

  ## Events from the panel's own buttons

  @impl Phoenix.LiveComponent
  def handle_event("lv_tab", %{"tab" => tab}, socket) do
    case tab in LiveViewSections.sub_tabs() do
      true -> {:noreply, socket |> assign(:lv_tab, tab) |> snapshot_if_shown() |> tree_if_shown()}
      false -> {:noreply, socket}
    end
  end

  def handle_event("lv_snapshot", _params, socket), do: {:noreply, start_snapshot(socket)}

  # Reads return the owner they read: a read of the previous LiveView that
  # finished just before the page change was handled is dropped, never shown
  # as the new page's.
  @impl Phoenix.LiveComponent
  def handle_async(
        key,
        {:ok, {owner, _result}},
        %{assigns: %{page: %Page{owner: current}}} = socket
      )
      when key in [:snapshot, :tree] and is_pid(current) and owner != current,
      do: {:noreply, socket}

  def handle_async(:snapshot, {:ok, {_owner, snapshot}}, socket),
    do: {:noreply, assign(socket, snapshot: snapshot, snapshot_pending?: false)}

  def handle_async(_key, {:exit, {:shutdown, :page_changed}}, socket), do: {:noreply, socket}

  def handle_async(:snapshot, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, snapshot: {:missing, :gone}, snapshot_pending?: false)}

  def handle_async(:tree, {:ok, {_owner, tree}}, socket),
    do: {:noreply, socket |> assign(tree: tree, tree_pending?: false) |> schedule_tree()}

  def handle_async(:tree, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(tree_pending?: false) |> schedule_tree()}

  ## Event log

  defp insert_events(socket, events),
    do: Enum.reduce(events, socket, &stream_insert(&2, :lv_events, &1, limit: -@dom_limit))

  defp reinsert_recent_client(socket) do
    socket.assigns.recent_client
    |> ClientEvent.recent(now_ms())
    |> Enum.reduce(socket, &stream_insert(&2, :lv_events, &1, limit: -@dom_limit))
  end

  defp dom_id(%Event{plugin: :client, data: %{n: n}}), do: "pdt-lv-client-#{n}"
  defp dom_id(%Event{seq: seq}), do: "pdt-lv-#{seq}"

  defp last_changed(%Event{kind: :callback, data: %{changes: %{keys: keys}}}, _acc), do: keys
  defp last_changed(_event, acc), do: acc

  defp now_ms, do: System.monotonic_time(:millisecond)

  ## Reads and page changes
  #
  # A snapshot or tree read started for the previous LiveView must not land on
  # the new one: stop it and let the caller start a fresh read. LiveView still
  # delivers the cancelled task's exit ({:shutdown, :page_changed}) unless a new
  # read with the same key replaced it: handle_async ignores it.

  defp drop_reads(socket) do
    socket
    |> cancel_async(:snapshot, {:shutdown, :page_changed})
    |> cancel_async(:tree, {:shutdown, :page_changed})
    |> assign(snapshot_pending?: false, tree_pending?: false)
  end

  ## Assigns snapshot
  #
  # Phoenix.LiveView.Debug.socket/1 is a GenServer.call to the host LiveView
  # that copies its whole socket: it runs in a task, which also truncates, so
  # only the bounded snapshot reaches this process (ADR 07).

  defp snapshot_if_shown(%{assigns: %{shown?: true, lv_tab: "assigns"}} = socket),
    do: start_snapshot(socket)

  defp snapshot_if_shown(socket), do: socket

  # New callbacks refresh a shown snapshot, at most once per @snapshot_ms; a
  # throttled refresh is scheduled, so the last callback is never missed.
  defp snapshot_after(
         %{assigns: %{shown?: true, lv_tab: "assigns", visible?: true}} = socket,
         events
       ) do
    case Enum.any?(events, &match?(%Event{kind: :callback}, &1)) do
      true -> throttled_snapshot(socket, wait_ms(socket.assigns.snapshot_at))
      false -> socket
    end
  end

  defp snapshot_after(socket, _events), do: socket

  defp wait_ms(nil), do: 0
  defp wait_ms(at), do: max(at + @snapshot_ms - System.monotonic_time(:millisecond), 0)

  defp throttled_snapshot(socket, 0), do: start_snapshot(socket)

  defp throttled_snapshot(%{assigns: %{snapshot_timer: ref}} = socket, _wait) when ref != nil,
    do: socket

  defp throttled_snapshot(socket, wait) do
    ref = Panel.send_after(LiveView, socket.assigns.id, :snapshot, wait)
    assign(socket, :snapshot_timer, ref)
  end

  defp start_snapshot(%{assigns: %{snapshot_pending?: true}} = socket), do: socket

  defp start_snapshot(socket) do
    case live_view_owner(socket.assigns.page) do
      nil ->
        assign(socket, :snapshot, {:missing, :no_live_view})

      owner ->
        socket
        |> assign(snapshot_pending?: true, snapshot_at: System.monotonic_time(:millisecond))
        |> start_async(:snapshot, fn -> {owner, take_snapshot(owner)} end)
    end
  end

  defp take_snapshot(owner) do
    case LiveViewAssigns.fetch(owner) do
      {:ok, assigns} -> Truncate.snapshot(assigns)
      :error -> {:missing, :gone}
    end
  end

  ## Component tree
  #
  # Polled every @tree_ms through Phoenix.LiveView.Debug, in a task, only while
  # the Components sub-tab is shown and the panel is open and visible. Opening
  # the sub-tab reads it once even before the hook reports visibility.

  defp tree_if_shown(%{assigns: %{shown?: true, lv_tab: "components"}} = socket),
    do: start_tree(socket)

  defp tree_if_shown(socket), do: socket

  defp polling?(%{assigns: %{shown?: true, lv_tab: "components", visible?: true}}), do: true
  defp polling?(_socket), do: false

  defp poll_tree(socket) do
    case polling?(socket) do
      true -> start_tree(socket)
      false -> socket
    end
  end

  defp schedule_tree(%{assigns: %{tree_timer: nil}} = socket) do
    case polling?(socket) do
      true ->
        assign(
          socket,
          :tree_timer,
          Panel.send_after(LiveView, socket.assigns.id, :tree_poll, @tree_ms)
        )

      false ->
        socket
    end
  end

  defp schedule_tree(socket), do: socket

  defp start_tree(%{assigns: %{tree_pending?: true}} = socket), do: socket

  defp start_tree(socket) do
    case live_view_owner(socket.assigns.page) do
      nil ->
        assign(socket, :tree, {:missing, :no_live_view})

      owner ->
        pids = live_view_pids(socket.assigns.page)

        socket
        |> assign(:tree_pending?, true)
        |> start_async(:tree, fn -> {owner, ComponentTree.read(owner, pids)} end)
    end
  end

  defp live_view_pids(%Page{sids: sids}),
    do: Enum.flat_map(sids, fn sid -> safe(fn -> Store.pids_for(sid) end, []) end)

  defp live_view_owner(page), do: LiveViewAssigns.owner(page)

  # The Store's tables vanish while it restarts: the panel shows what it can.
  defp safe(fun, fallback) do
    fun.()
  rescue
    ArgumentError -> fallback
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="pdt-lv">
      <LiveViewSections.section
        tab={@lv_tab}
        profile={@profile}
        snapshot={@snapshot}
        snapshot_pending?={@snapshot_pending?}
        last_changed={@last_changed}
        tree={@tree}
        tree_pending?={@tree_pending?}
        client_dropped={@client_dropped}
        polling?={@shown? and @lv_tab == "components" and @visible?}
        events={@streams.lv_events}
        root={@page.root}
        target={@myself}
      />
    </div>
    """
  end
end
