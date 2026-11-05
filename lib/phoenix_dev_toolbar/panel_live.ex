defmodule PhoenixDevToolbar.PanelLive do
  @moduledoc false
  # The toolbar panel, rendered in the iframe the loader creates (ADR 04).
  # Opened as `<path>/panel?sid=<request sid>`; shows the page made of that
  # request and its LiveView (see PhoenixDevToolbar.Page), live:
  #
  #   {:pdt_event, sid}    new events: re-read from the Store, at most every 100 ms
  #   {:pdt_session, sid}  the page changed (LiveView connected, live navigation)
  #
  # Being under `PhoenixDevToolbar.`, this LiveView is never tracked itself.

  use Phoenix.LiveView

  import PhoenixDevToolbar.Components

  alias PhoenixDevToolbar.ClientEvent
  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.ComponentTree
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.Page
  alias PhoenixDevToolbar.Panels
  alias PhoenixDevToolbar.Profile
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Shell
  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.Truncate

  @flush_ms 100
  # At most one assigns snapshot per second while the Assigns sub-tab is shown.
  @snapshot_ms 1000
  # Component tree poll interval, only while shown, open and visible.
  @tree_ms 2000
  # Rows kept in the DOM per list; the Store keeps 500 events per plugin and page.
  @dom_limit 500
  # Seqs are allocated before their row is written, so concurrent writers on one
  # session can land out of order: each flush re-reads this many seqs below the
  # last one seen and skips the ones already shown.
  @reread_window 64
  @sid_format ~r/^[A-Za-z0-9_-]{1,64}$/

  @impl true
  # Rendered by PhoenixDevToolbar.Plug without a router: the sid comes from the
  # signed LiveView session, there are no route params.
  def mount(_params, session, socket) do
    root = valid_sid(session["pdt_sid"])
    shell = Shell.new(Collector.plugins())
    tabs = Shell.tabs(shell)

    socket =
      socket
      |> assign(shell: shell, tabs: tabs, tab: default_tab(tabs))
      |> assign(root: root, lv_tab: "profiler", flush: nil, subscribed: [])
      |> assign(snapshot: nil, snapshot_pending?: false, snapshot_at: nil, snapshot_timer: nil)
      |> assign(last_changed: [], visible?: false)
      |> assign(tree: nil, tree_pending?: false, tree_timer: nil)
      |> stream_configure(:lv_events, dom_id: &lv_dom_id/1)
      |> assign(client_count: 0, client_dropped: 0, recent_client: [])
      # Subscribe before reading: a LiveView announced between the read and the
      # subscription would otherwise never reach the panel.
      |> subscribe(List.wrap(root))

    {:ok, load(socket, root)}
  end

  @impl true
  # Tab ids are compared as strings: never an atom from the client.
  def handle_event("tab", %{"tab" => tab}, socket) do
    case tab in tab_ids(socket.assigns.tabs) do
      true -> {:noreply, socket |> assign(:tab, tab) |> snapshot_if_shown() |> tree_if_shown()}
      false -> {:noreply, socket}
    end
  end

  def handle_event("lv_tab", %{"tab" => tab}, socket) do
    case tab in Panels.LiveView.sub_tabs() do
      true -> {:noreply, socket |> assign(:lv_tab, tab) |> snapshot_if_shown() |> tree_if_shown()}
      false -> {:noreply, socket}
    end
  end

  def handle_event("lv_snapshot", _params, socket), do: {:noreply, start_snapshot(socket)}

  # From the PdtPanel hook: a client event the loader forwarded (untrusted input).
  # A nil event only updates the drop count (the loader reports drops on its own).
  def handle_event("pdt:client", %{} = params, socket) do
    n = socket.assigns.client_count + 1
    dropped = ClientEvent.dropped(params["dropped"], socket.assigns.client_dropped)
    socket = assign(socket, :client_dropped, dropped)

    case ClientEvent.build(params["event"], n) do
      {:ok, client} ->
        recent = ClientEvent.remember(socket.assigns.recent_client, client, now_ms())

        {:noreply,
         socket
         |> assign(client_count: n, recent_client: recent)
         |> stream_insert(:lv_events, client, limit: -@dom_limit)}

      :ignore ->
        {:noreply, socket}
    end
  end

  # From the PdtPanel hook: the loader's open state and the browser tab's visibility.
  def handle_event("pdt:visibility", params, socket) do
    visible? = params["open"] == true and params["visible"] == true

    socket = assign(socket, :visible?, visible?)

    case visible? do
      true -> {:noreply, tree_if_shown(socket)}
      false -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:pdt_event, _sid}, %{assigns: %{flush: nil}} = socket),
    do: {:noreply, assign(socket, :flush, Process.send_after(self(), :pdt_flush, @flush_ms))}

  def handle_info({:pdt_event, _sid}, socket), do: {:noreply, socket}

  def handle_info(:pdt_flush, socket), do: {:noreply, socket |> cancel_flush() |> flush()}

  def handle_info({:pdt_session, sid}, %{assigns: %{page: %Page{} = page}} = socket) do
    with {:ok, child} <- safe(fn -> Store.session(sid) end, :error),
         {change, next} <- Page.follow(page, child) do
      {:noreply, apply_change(socket, change, next)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_info(:pdt_snapshot, socket),
    do: {:noreply, socket |> assign(:snapshot_timer, nil) |> snapshot_if_shown()}

  def handle_info(:pdt_tree_poll, socket),
    do: {:noreply, socket |> assign(:tree_timer, nil) |> poll_tree()}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:snapshot, {:ok, snapshot}, socket),
    do: {:noreply, assign(socket, snapshot: snapshot, snapshot_pending?: false)}

  def handle_async(_key, {:exit, {:shutdown, :page_changed}}, socket), do: {:noreply, socket}

  def handle_async(:snapshot, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, snapshot: {:missing, :gone}, snapshot_pending?: false)}

  def handle_async(:tree, {:ok, tree}, socket),
    do: {:noreply, socket |> assign(tree: tree, tree_pending?: false) |> schedule_tree()}

  def handle_async(:tree, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(tree_pending?: false) |> schedule_tree()}

  ## Loading

  # Derives the page once, at mount. Later changes arrive as notifications.
  defp load(socket, nil), do: show(socket, %Page{}, [])

  defp load(socket, root) do
    case safe(fn -> Page.initial(root) end, nil) do
      %Page{sids: sids} = page ->
        socket |> subscribe(sids) |> show(page, read_all(sids))

      nil ->
        show(socket, %Page{root: root}, [])
    end
  end

  # The first LiveView joined: add it, keep what the request already showed.
  defp apply_change(socket, :connected, %Page{} = page) do
    [_root, live] = page.sids
    events = read_all([live])

    socket
    |> subscribe([live])
    |> assign(page: page)
    |> fold(events)
    |> remember(events)
    |> insert_all(events)
    |> drop_reads()
    |> snapshot_if_shown()
    |> tree_if_shown()
  end

  # Live navigation: a new page in the same tab replaces everything.
  defp apply_change(socket, :navigated, %Page{sids: sids} = page) do
    socket
    |> unsubscribe(socket.assigns.page.sids -- [socket.assigns.root])
    |> subscribe(sids)
    |> show(page, read_all(sids))
    |> reinsert_recent_client()
    |> drop_reads()
    |> snapshot_if_shown()
    |> tree_if_shown()
  end

  defp apply_change(socket, :rejoined, %Page{} = page),
    do: socket |> assign(:page, page) |> drop_reads() |> snapshot_if_shown() |> tree_if_shown()

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

  defp show(socket, %Page{sids: sids} = page, events) do
    socket
    |> assign(
      page: page,
      missing?: sids == [],
      shell: Shell.reset(socket.assigns.shell, events),
      profile: Profile.new(events),
      last_changed: Enum.reduce(events, [], &last_changed/2),
      snapshot: nil,
      tree: nil,
      gaps: gaps(sids)
    )
    |> assign(seqs: %{}, seen: MapSet.new())
    |> remember(events)
    |> deliver(:reset, events)
    |> stream(:lv_events, Enum.filter(events, &live_view?/1), reset: true, limit: -@dom_limit)
  end

  defp flush(%{assigns: %{page: %Page{sids: sids}, seqs: seqs, seen: seen}} = socket) do
    lows = Map.new(sids, &{&1, max(Map.get(seqs, &1, 0) - @reread_window, 0)})

    events =
      sids
      |> Enum.flat_map(fn sid -> safe(fn -> Store.events(sid, lows[sid]) end, []) end)
      |> Enum.reject(&MapSet.member?(seen, &1.seq))
      |> Enum.sort_by(& &1.seq)

    socket
    |> fold(events)
    |> assign(:gaps, gaps(sids))
    |> remember(events)
    |> forget_below(lows)
    |> insert_all(events)
    |> snapshot_after(events)
  end

  defp lv_dom_id(%Event{plugin: :client, data: %{n: n}}), do: "pdt-lv-client-#{n}"
  defp lv_dom_id(%Event{seq: seq}), do: "pdt-lv-#{seq}"

  defp now_ms, do: System.monotonic_time(:millisecond)

  # After a reset of the log: the client events that announced the navigation.
  defp reinsert_recent_client(socket) do
    socket.assigns.recent_client
    |> ClientEvent.recent(now_ms())
    |> Enum.reduce(socket, &stream_insert(&2, :lv_events, &1, limit: -@dom_limit))
  end

  # Summaries and profile are folded incrementally, never rebuilt from the Store.
  defp fold(socket, events) do
    assign(socket,
      shell: Shell.fold(socket.assigns.shell, events),
      profile: Enum.reduce(events, socket.assigns.profile, &Profile.add(&2, &1)),
      last_changed: Enum.reduce(events, socket.assigns.last_changed, &last_changed/2)
    )
  end

  defp last_changed(%Event{kind: :callback, data: %{changes: %{keys: keys}}}, _acc), do: keys
  defp last_changed(_event, acc), do: acc

  ## Assigns snapshot
  #
  # Phoenix.LiveView.Debug.socket/1 is a GenServer.call to the host LiveView
  # that copies its whole socket: it runs in a task (start_async), which also
  # truncates, so only the bounded snapshot reaches this process (ADR 07).

  defp snapshot_if_shown(%{assigns: %{tab: "live_view", lv_tab: "assigns"}} = socket),
    do: start_snapshot(socket)

  defp snapshot_if_shown(socket), do: socket

  # New callbacks refresh a shown snapshot, at most once per @snapshot_ms; a
  # throttled refresh is scheduled, so the last callback is never missed.
  defp snapshot_after(
         %{assigns: %{tab: "live_view", lv_tab: "assigns", visible?: true}} = socket,
         events
       ) do
    case Enum.any?(events, &match?(%Event{plugin: :live_view, kind: :callback}, &1)) do
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

  defp throttled_snapshot(socket, wait),
    do: assign(socket, :snapshot_timer, Process.send_after(self(), :pdt_snapshot, wait))

  defp start_snapshot(%{assigns: %{snapshot_pending?: true}} = socket), do: socket

  defp start_snapshot(socket) do
    case live_view_owner(socket.assigns.page) do
      nil ->
        assign(socket, :snapshot, {:missing, :no_live_view})

      owner ->
        socket
        |> assign(snapshot_pending?: true, snapshot_at: System.monotonic_time(:millisecond))
        |> start_async(:snapshot, fn -> take_snapshot(owner) end)
    end
  end

  defp take_snapshot(owner) do
    case Phoenix.LiveView.Debug.socket(owner) do
      {:ok, %{assigns: assigns}} -> Truncate.snapshot(assigns)
      {:error, _reason} -> {:missing, :gone}
    end
  end

  ## Component tree
  #
  # Polled every @tree_ms through Phoenix.LiveView.Debug, in a task, only while
  # the Components sub-tab is shown and the panel is open and visible. Opening
  # the sub-tab reads it once even before the hook reports visibility.

  defp tree_if_shown(%{assigns: %{tab: "live_view", lv_tab: "components"}} = socket),
    do: start_tree(socket)

  defp tree_if_shown(socket), do: socket

  defp polling?(%{assigns: %{tab: "live_view", lv_tab: "components", visible?: true}}), do: true
  defp polling?(_socket), do: false

  defp poll_tree(socket) do
    case polling?(socket) do
      true -> start_tree(socket)
      false -> socket
    end
  end

  defp schedule_tree(%{assigns: %{tree_timer: nil}} = socket) do
    case polling?(socket) do
      true -> assign(socket, :tree_timer, Process.send_after(self(), :pdt_tree_poll, @tree_ms))
      false -> socket
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
        |> start_async(:tree, fn -> ComponentTree.read(owner, pids) end)
    end
  end

  defp live_view_pids(%Page{sids: sids}),
    do: Enum.flat_map(sids, fn sid -> safe(fn -> Store.pids_for(sid) end, []) end)

  # The page's newest LiveView (read now: a rejoin changes the owner).
  defp live_view_owner(%Page{sids: sids}) do
    sids
    |> Enum.reverse()
    |> Enum.find_value(fn sid ->
      case safe(fn -> Store.session(sid) end, :error) do
        {:ok, %Session{kind: :live_view, owner: owner}} when is_pid(owner) -> owner
        _other -> nil
      end
    end)
  end

  # Events over the flood guard budget (dropped) and the oldest events past the
  # per plugin and per page caps (trimmed) are counted, not stored: show the gaps.
  defp gaps(sids) do
    Enum.reduce(sids, %{dropped: 0, trimmed: 0, by_plugin: %{}}, fn sid, gaps ->
      case safe(fn -> Store.session(sid) end, :error) do
        {:ok, session} ->
          %{
            dropped: gaps.dropped + session.dropped,
            trimmed: gaps.trimmed + session.trimmed,
            by_plugin: add_trimmed(gaps.by_plugin, safe(fn -> Store.plugin_counts(sid) end, %{}))
          }

        :error ->
          gaps
      end
    end)
  end

  defp add_trimmed(acc, counts) do
    Enum.reduce(counts, acc, fn {plugin, %{trimmed: n}}, acc ->
      Map.update(acc, Atom.to_string(plugin), n, &(&1 + n))
    end)
  end

  defp read_all(sids) do
    sids
    |> Enum.flat_map(fn sid -> safe(fn -> Store.events(sid) end, []) end)
    |> Enum.sort_by(& &1.seq)
  end

  defp insert_all(socket, events) do
    events
    |> Enum.filter(&live_view?/1)
    |> Enum.reduce(socket, &stream_insert(&2, :lv_events, &1, limit: -@dom_limit))
    |> deliver(:events, events)
  end

  # Each tab's component gets its plugin's events (send_update: delivered after
  # this callback, in order). A reset reaches every tab, even with no events.
  defp deliver(socket, kind, events) do
    routed = Shell.route(socket.assigns.shell, events)

    for %{id: id, panel: panel} <- socket.assigns.tabs,
        tab_events = Map.get(routed, id, []),
        kind == :reset or tab_events != [] do
      send_update(panel, id: panel_id(id), pdt: {kind, tab_events})
    end

    socket
  end

  defp panel_id(tab_id), do: "pdt-panel-" <> tab_id

  # The LiveView tab is not on the plugin shell yet (Phase 3 task 4).
  defp tab_ids(tabs), do: Enum.map(tabs, & &1.id) ++ ["live_view"]

  defp default_tab([%{id: id} | _tabs]), do: id
  defp default_tab([]), do: "live_view"

  # Tracks the highest seq per sid and the seqs already shown (for the re-read
  # window); `forget_below/2` keeps `seen` bounded to that window.
  defp remember(socket, events) do
    seqs =
      Enum.reduce(events, socket.assigns.seqs, fn %Event{sid: sid, seq: seq}, acc ->
        Map.update(acc, sid, seq, &max(&1, seq))
      end)

    assign(socket, seqs: seqs, seen: Enum.into(events, socket.assigns.seen, & &1.seq))
  end

  defp forget_below(socket, lows) do
    floor = lows |> Map.values() |> Enum.min(fn -> 0 end)
    update(socket, :seen, &MapSet.filter(&1, fn seq -> seq >= floor end))
  end

  defp subscribe(socket, sids) do
    new = Enum.reject(sids, &(&1 in socket.assigns.subscribed))
    maybe_connected(socket, fn -> Enum.each(new, &Notify.subscribe/1) end)
    assign(socket, :subscribed, socket.assigns.subscribed ++ new)
  end

  defp unsubscribe(socket, sids) do
    maybe_connected(socket, fn -> Enum.each(sids, &Notify.unsubscribe/1) end)
    assign(socket, :subscribed, socket.assigns.subscribed -- sids)
  end

  defp maybe_connected(socket, fun) do
    case connected?(socket) do
      true -> fun.()
      false -> :ok
    end
  end

  # The Store's tables vanish while it restarts: the panel shows what it can.
  defp safe(fun, fallback) do
    fun.()
  rescue
    ArgumentError -> fallback
  end

  defp cancel_flush(%{assigns: %{flush: nil}} = socket), do: socket

  defp cancel_flush(%{assigns: %{flush: ref}} = socket) do
    Process.cancel_timer(ref)
    assign(socket, :flush, nil)
  end

  defp live_view?(%Event{plugin: :live_view}), do: true
  defp live_view?(_event), do: false

  defp valid_sid(sid) when is_binary(sid) do
    case Regex.match?(@sid_format, sid) do
      true -> sid
      false -> nil
    end
  end

  defp valid_sid(_sid), do: nil

  ## Rendering

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :tab_labels,
        Enum.map(assigns.tabs, &{&1.id, &1.name}) ++ [{"live_view", "LiveView"}]
      )

    ~H"""
    <div id="pdt-panel" class="pdt-panel">
      <%!-- The hook lives on its own empty element: LiveView locks a hook's
           element while its pushEvent is in flight, and a diff landing in a
           locked tree loses its stream resets (seen on live navigation). --%>
      <div id="pdt-bridge" phx-hook="PdtPanel" hidden></div>
      <header class="pdt-header">
        <span class="pdt-logo">dev toolbar</span>
        <.summary_bar badges={Shell.badges(@shell)} dropped={@gaps.dropped} trimmed={@gaps.trimmed} />
        <nav class="pdt-tabs" role="tablist">
          <button
            :for={{tab, label} <- @tab_labels}
            id={"pdt-tab-" <> tab}
            type="button"
            role="tab"
            aria-selected={to_string(@tab == tab)}
            aria-controls={"pdt-section-" <> tab}
            tabindex={if(@tab == tab, do: "0", else: "-1")}
            class={["pdt-tab", @tab == tab && "pdt-tab--active"]}
            phx-click="tab"
            phx-value-tab={tab}
          >
            {label}
          </button>
        </nav>
        <button
          id="pdt-hide"
          type="button"
          class="pdt-hide"
          data-pdt-hide
          aria-label="Hide the toolbar to a corner badge"
          title="Hide"
        >
          <span aria-hidden="true">&times;</span>
        </button>
        <button
          id="pdt-toggle"
          type="button"
          class="pdt-toggle"
          data-pdt-toggle
          aria-label="Expand or collapse the toolbar"
        >
          <span class="pdt-toggle__icon" aria-hidden="true"></span>
        </button>
      </header>

      <p :if={@missing?} id="pdt-empty" class="pdt-empty">
        No data for this page: it expired or the toolbar restarted. Reload the page.
      </p>

      <section
        :for={tab <- @tabs}
        id={"pdt-section-" <> tab.id}
        class="pdt-section"
        role="tabpanel"
        aria-labelledby={"pdt-tab-" <> tab.id}
        hidden={@tab != tab.id}
      >
        <p
          :if={Map.get(@gaps.by_plugin, tab.id, 0) > 0}
          id={"pdt-trimmed-" <> tab.id}
          class="pdt-hint"
        >
          {Map.get(@gaps.by_plugin, tab.id)} older events trimmed: the list starts later than the page.
        </p>
        <.live_component
          module={tab.panel}
          id={panel_id(tab.id)}
          config={tab.config}
          page={@page}
          shown?={@tab == tab.id}
          visible?={@visible?}
        />
      </section>

      <section
        id="pdt-section-live_view"
        class="pdt-section"
        role="tabpanel"
        aria-labelledby="pdt-tab-live_view"
        hidden={@tab != "live_view"}
      >
        <Panels.LiveView.section
          tab={@lv_tab}
          profile={@profile}
          snapshot={@snapshot}
          snapshot_pending?={@snapshot_pending?}
          last_changed={@last_changed}
          tree={@tree}
          tree_pending?={@tree_pending?}
          client_dropped={@client_dropped}
          polling?={@tab == "live_view" and @lv_tab == "components" and @visible?}
          events={@streams.lv_events}
          root={@page.root}
        />
      </section>
    </div>
    """
  end
end
