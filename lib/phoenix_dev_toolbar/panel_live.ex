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

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.Page
  alias PhoenixDevToolbar.Panels
  alias PhoenixDevToolbar.Profile
  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.Summary

  @flush_ms 100
  @tabs ~w(ecto request live_view)
  @tab_labels [{"ecto", "Ecto"}, {"request", "Request"}, {"live_view", "LiveView"}]
  # Rows kept in the DOM per list; the Store keeps 500 events per session.
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

    socket =
      socket
      |> assign(root: root, tab: "ecto", lv_tab: "profiler", flush: nil, subscribed: [])
      |> stream_configure(:queries, dom_id: &"pdt-query-#{&1.seq}")
      |> stream_configure(:requests, dom_id: &"pdt-request-#{&1.seq}")
      |> stream_configure(:lv_events, dom_id: &"pdt-lv-#{&1.seq}")
      # Subscribe before reading: a LiveView announced between the read and the
      # subscription would otherwise never reach the panel.
      |> subscribe(List.wrap(root))

    {:ok, load(socket, root)}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in @tabs,
    do: {:noreply, assign(socket, :tab, tab)}

  def handle_event("tab", _params, socket), do: {:noreply, socket}

  def handle_event("lv_tab", %{"tab" => tab}, socket) do
    case tab in Panels.LiveView.sub_tabs() do
      true -> {:noreply, assign(socket, :lv_tab, tab)}
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
  defp apply_change(socket, :connected, %Page{} = page) do
    [_root, live] = page.sids
    events = read_all([live])

    socket
    |> subscribe([live])
    |> assign(page: page)
    |> fold(events)
    |> remember(events)
    |> insert_all(events)
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
      summary: Summary.new(events),
      profile: Profile.new(events),
      dropped: dropped(sids)
    )
    |> assign(seqs: %{}, seen: MapSet.new())
    |> remember(events)
    |> stream(:queries, Enum.filter(events, &query?/1), reset: true, limit: -@dom_limit)
    |> stream(:requests, Enum.filter(events, &request?/1), reset: true, limit: -@dom_limit)
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
    |> assign(:dropped, dropped(sids))
    |> remember(events)
    |> forget_below(lows)
    |> insert_all(events)
  end

  # Summary and profile are folded incrementally, never rebuilt from the Store.
  defp fold(socket, events) do
    assign(socket,
      summary: Enum.reduce(events, socket.assigns.summary, &Summary.add(&2, &1)),
      profile: Enum.reduce(events, socket.assigns.profile, &Profile.add(&2, &1))
    )
  end

  # Events over the flood guard budget are counted, not stored: show the gap.
  defp dropped(sids) do
    # Enum.reduce, not Enum.sum_by: Elixir 1.17 is supported.
    Enum.reduce(sids, 0, fn sid, total ->
      case safe(fn -> Store.session(sid) end, :error) do
        {:ok, session} -> total + session.dropped
        :error -> total
      end
    end)
  end

  defp read_all(sids) do
    sids
    |> Enum.flat_map(fn sid -> safe(fn -> Store.events(sid) end, []) end)
    |> Enum.sort_by(& &1.seq)
  end

  defp insert_all(socket, events), do: Enum.reduce(events, socket, &insert/2)

  defp insert(%Event{} = event, socket) do
    cond do
      query?(event) -> stream_insert(socket, :queries, event, limit: -@dom_limit)
      request?(event) -> stream_insert(socket, :requests, event, limit: -@dom_limit)
      live_view?(event) -> stream_insert(socket, :lv_events, event, limit: -@dom_limit)
      true -> socket
    end
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

  defp query?(%Event{plugin: :ecto, kind: :query}), do: true
  defp query?(_event), do: false

  defp request?(%Event{plugin: :request}), do: true
  defp request?(_event), do: false

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
    assigns = assign(assigns, :tab_labels, @tab_labels)

    ~H"""
    <div id="pdt-panel" class="pdt-panel">
      <header class="pdt-header">
        <span class="pdt-logo">dev toolbar</span>
        <.summary_bar summary={@summary} dropped={@dropped} />
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
        id="pdt-section-ecto"
        class="pdt-section"
        role="tabpanel"
        aria-labelledby="pdt-tab-ecto"
        hidden={@tab != "ecto"}
      >
        <ul id="pdt-queries" class="pdt-list" phx-update="stream">
          <li id="pdt-queries-empty" class="pdt-list__empty">No queries yet.</li>
          <.query_row :for={{id, event} <- @streams.queries} id={id} event={event} root={@page.root} />
        </ul>
      </section>

      <section
        id="pdt-section-request"
        class="pdt-section"
        role="tabpanel"
        aria-labelledby="pdt-tab-request"
        hidden={@tab != "request"}
      >
        <ul id="pdt-requests" class="pdt-list" phx-update="stream">
          <li id="pdt-requests-empty" class="pdt-list__empty">No requests yet.</li>
          <.request_row :for={{id, event} <- @streams.requests} id={id} event={event} />
        </ul>
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
          events={@streams.lv_events}
          root={@page.root}
        />
      </section>
    </div>
    """
  end
end
