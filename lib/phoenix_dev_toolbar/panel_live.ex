defmodule PhoenixDevToolbar.PanelLive do
  @moduledoc false
  # The toolbar panel, rendered in the iframe the loader creates (ADR 04).
  # Opened as `<path>/panel?sid=<request sid>`; shows the page made of that
  # request and its LiveView (see PhoenixDevToolbar.Page), live:
  #
  #   {:pdt_event, sid}    new events: re-read from the Store, at most every 100 ms
  #   {:pdt_session, sid}  the page changed (LiveView connected, live navigation)
  #
  # Generic glue (ADR 05): every tab is a plugin's panel component, fed its
  # plugin's events (PhoenixDevToolbar.Panel); badges come from the plugins'
  # summaries (PhoenixDevToolbar.Shell). Being under `PhoenixDevToolbar.`, this
  # LiveView is never tracked itself.

  use Phoenix.LiveView

  import PhoenixDevToolbar.Components

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.Page
  alias PhoenixDevToolbar.Panel
  alias PhoenixDevToolbar.Shell
  alias PhoenixDevToolbar.Store

  @flush_ms 100
  # Seqs are allocated before their row is written, so concurrent writers on one
  # session can land out of order: each flush re-reads this many seqs below the
  # last one seen and skips the ones already shown.
  @reread_window 64
  @sid_format ~r/^[A-Za-z0-9_-]{1,64}$/
  # The tab the PdtPanel hook's client events go to (ADR 07).
  @client_tab "live_view"

  @impl true
  # Rendered by PhoenixDevToolbar.Plug without a router: the sid comes from the
  # signed LiveView session, there are no route params.
  def mount(_params, session, socket) do
    root = valid_sid(session["pdt_sid"])
    shell = Shell.new(Collector.plugins())
    tabs = Shell.tabs(shell)

    socket =
      socket
      |> assign(shell: shell, tabs: tabs, tab: default_tab(tabs), visible?: false)
      |> assign(root: root, flush: nil, subscribed: [])
      # Subscribe before reading: a LiveView announced between the read and the
      # subscription would otherwise never reach the panel.
      |> subscribe(List.wrap(root))

    {:ok, load(socket, root)}
  end

  @impl true
  # Tab ids are compared as strings: never an atom from the client.
  def handle_event("tab", %{"tab" => tab}, socket) do
    case Enum.any?(socket.assigns.tabs, &(&1.id == tab)) do
      true -> {:noreply, assign(socket, :tab, tab)}
      false -> {:noreply, socket}
    end
  end

  # From the PdtPanel hook: a client event the loader forwarded (untrusted
  # input), validated by the LiveView tab (PhoenixDevToolbar.ClientEvent).
  def handle_event("pdt:client", %{} = params, socket) do
    case Enum.find(socket.assigns.tabs, &(&1.id == @client_tab)) do
      %{panel: panel} -> Panel.send_now(self(), panel, panel_id(@client_tab), {:client, params})
      nil -> :ok
    end

    {:noreply, socket}
  end

  # From the PdtPanel hook: the loader's open state and the browser tab's visibility.
  def handle_event("pdt:visibility", params, socket),
    do:
      {:noreply, assign(socket, :visible?, params["open"] == true and params["visible"] == true)}

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

  def handle_info(_message, socket), do: {:noreply, socket}

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
  # Tabs see the new page in their props (handle_props) and its events.
  defp apply_change(socket, :connected, %Page{} = page) do
    [_root, live] = page.sids
    events = read_all([live])

    socket
    |> subscribe([live])
    |> assign(page: page)
    |> fold(events)
    |> remember(events)
    |> deliver(:events, events)
  end

  # Live navigation: a new page in the same tab replaces everything.
  defp apply_change(socket, :navigated, %Page{sids: sids} = page) do
    socket
    |> unsubscribe(socket.assigns.page.sids -- [socket.assigns.root])
    |> subscribe(sids)
    |> show(page, read_all(sids))
  end

  defp apply_change(socket, :rejoined, %Page{} = page), do: assign(socket, :page, page)

  defp show(socket, %Page{sids: sids} = page, events) do
    socket
    |> assign(
      page: page,
      missing?: sids == [],
      shell: Shell.reset(socket.assigns.shell, events),
      gaps: gaps(sids)
    )
    |> assign(seqs: %{}, seen: MapSet.new())
    |> remember(events)
    |> deliver(:reset, events)
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
    |> deliver(:events, events)
  end

  # Summaries are folded incrementally, never rebuilt from the Store.
  defp fold(socket, events), do: assign(socket, :shell, Shell.fold(socket.assigns.shell, events))

  # Each tab's component gets its plugin's events (send_update: delivered after
  # this callback, in order). A reset reaches every tab, even with no events.
  # Only once connected: the dead render's process would just drop them, so
  # the dead render shows empty tabs, filled on connect.
  defp deliver(socket, kind, events) do
    maybe_connected(socket, fn ->
      routed = Shell.route(socket.assigns.shell, events)

      for %{id: id, panel: panel} <- socket.assigns.tabs,
          tab_events = Map.get(routed, id, []),
          kind == :reset or tab_events != [] do
        send_update(panel, id: panel_id(id), pdt: {kind, tab_events})
      end
    end)

    socket
  end

  defp panel_id(tab_id), do: "pdt-panel-" <> tab_id

  defp default_tab([%{id: id} | _tabs]), do: id
  defp default_tab([]), do: nil

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
            :for={tab <- @tabs}
            id={"pdt-tab-" <> tab.id}
            type="button"
            role="tab"
            aria-selected={to_string(@tab == tab.id)}
            aria-controls={"pdt-section-" <> tab.id}
            tabindex={if(@tab == tab.id, do: "0", else: "-1")}
            class={["pdt-tab", @tab == tab.id && "pdt-tab--active"]}
            phx-click="tab"
            phx-value-tab={tab.id}
          >
            {tab.name}
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
    </div>
    """
  end
end
