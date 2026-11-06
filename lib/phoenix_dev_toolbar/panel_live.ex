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

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.Page
  alias PhoenixDevToolbar.PageData
  alias PhoenixDevToolbar.Panel
  alias PhoenixDevToolbar.PanelLayout
  alias PhoenixDevToolbar.Shell

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
      |> assign(panel_errors: %{}, quarantined: PageData.quarantined(shell.plugins))
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

  # A disabled plugin's Re-enable button: release the collector's quarantine,
  # forget the panel errors, then reload the page into every tab.
  # Plugins without a tab are re-enabled from their badge.
  def handle_event("pdt_reenable", %{"tab" => tab}, socket) do
    case Enum.find(socket.assigns.shell.plugins, &(Atom.to_string(elem(&1, 0).id()) == tab)) do
      {plugin, _config} ->
        Collector.release(plugin)
        recover_tab(socket.assigns.tabs, tab)

        socket =
          socket
          |> assign(shell: Shell.mend(socket.assigns.shell, tab))
          |> update(:panel_errors, &Map.delete(&1, tab))

        {:noreply, show(socket, socket.assigns.page, PageData.read_all(socket.assigns.page.sids))}

      nil ->
        {:noreply, socket}
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
    with {:ok, child} <- PageData.session(sid),
         {change, next} <- Page.follow(page, child) do
      {:noreply, apply_change(socket, change, next)}
    else
      _ -> {:noreply, socket}
    end
  end

  # A tab's component raised (PhoenixDevToolbar.Panel boundary).
  def handle_info({:pdt_panel_error, "pdt-panel-" <> tab, banner}, socket) when is_binary(banner),
    do: {:noreply, update(socket, :panel_errors, &Map.put(&1, tab, banner))}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Loading

  # Derives the page once, at mount. Later changes arrive as notifications.
  defp load(socket, nil), do: show(socket, %Page{}, [])

  defp load(socket, root) do
    case PageData.safe(fn -> Page.initial(root) end, nil) do
      %Page{sids: sids} = page ->
        socket |> subscribe(sids) |> show(page, PageData.read_all(sids))

      nil ->
        show(socket, %Page{root: root}, [])
    end
  end

  # The first LiveView joined: add it, keep what the request already showed.
  # Tabs see the new page in their props (handle_props) and its events.
  defp apply_change(socket, :connected, %Page{} = page) do
    [_root, live] = page.sids
    events = PageData.read_all([live])

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
    |> show(page, PageData.read_all(sids))
  end

  defp apply_change(socket, :rejoined, %Page{} = page), do: assign(socket, :page, page)

  defp show(socket, %Page{sids: sids} = page, events) do
    socket
    |> assign(
      page: page,
      missing?: sids == [],
      shell: Shell.reset(socket.assigns.shell, events),
      gaps: PageData.gaps(sids),
      quarantined: PageData.quarantined(socket.assigns.shell.plugins)
    )
    |> assign(seqs: %{}, seen: %{})
    |> remember(events)
    |> deliver(:reset, events)
  end

  defp flush(%{assigns: %{page: %Page{sids: sids}, seqs: seqs, seen: seen}} = socket) do
    lows = Map.new(sids, &{&1, max(Map.get(seqs, &1, 0) - @reread_window, 0)})

    events = sids |> PageData.read_since(lows) |> Enum.reject(&seen?(seen, &1))

    socket
    |> fold(events)
    |> assign(
      gaps: PageData.gaps(sids),
      quarantined: PageData.quarantined(socket.assigns.shell.plugins)
    )
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

  defp panel_id(tab_id), do: PanelLayout.panel_id(tab_id)

  defp recover_tab(tabs, tab) do
    case Enum.find(tabs, &(&1.id == tab)) do
      %{panel: panel} -> send_update(panel, id: panel_id(tab), pdt: :recover)
      nil -> :ok
    end
  end

  defp default_tab([%{id: id} | _tabs]), do: id
  defp default_tab([]), do: nil

  # Tracks, per sid, the highest seq and the seqs already shown (for the
  # re-read window); `forget_below/2` keeps each sid's `seen` bounded to its
  # own window (one floor for all sids would keep a quiet sid's window open).
  defp remember(socket, events) do
    {seqs, seen} =
      Enum.reduce(events, {socket.assigns.seqs, socket.assigns.seen}, fn
        %Event{sid: sid, seq: seq}, {seqs, seen} ->
          {Map.update(seqs, sid, seq, &max(&1, seq)),
           Map.update(seen, sid, MapSet.new([seq]), &MapSet.put(&1, seq))}
      end)

    assign(socket, seqs: seqs, seen: seen)
  end

  defp seen?(seen, %Event{sid: sid, seq: seq}),
    do: seen |> Map.get(sid, MapSet.new()) |> MapSet.member?(seq)

  defp forget_below(socket, lows) do
    update(socket, :seen, fn seen ->
      Map.new(seen, fn {sid, seqs} ->
        low = Map.get(lows, sid, 0)
        {sid, MapSet.filter(seqs, &(&1 >= low))}
      end)
    end)
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
    <PanelLayout.panel
      shell={@shell}
      tabs={@tabs}
      tab={@tab}
      page={@page}
      gaps={@gaps}
      quarantined={@quarantined}
      panel_errors={@panel_errors}
      missing?={@missing?}
      visible?={@visible?}
    />
    """
  end
end
