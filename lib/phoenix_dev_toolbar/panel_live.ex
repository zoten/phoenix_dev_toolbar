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
  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.Summary

  @flush_ms 100
  @tabs ~w(ecto request)
  # Rows kept in the DOM per list; the Store keeps 500 events per session.
  @dom_limit 500
  @sid_format ~r/^[A-Za-z0-9_-]{1,64}$/

  @impl true
  # Rendered by PhoenixDevToolbar.Plug without a router: the sid comes from the
  # signed LiveView session, there are no route params.
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(root: valid_sid(session["pdt_sid"]), tab: "ecto", flush: nil)
      |> assign(sids: [], seqs: %{}, subscribed: [])
      |> stream_configure(:queries, dom_id: &"pdt-query-#{&1.seq}")
      |> stream_configure(:requests, dom_id: &"pdt-request-#{&1.seq}")

    {:ok, load(socket)}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in @tabs,
    do: {:noreply, assign(socket, :tab, tab)}

  def handle_event("tab", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:pdt_event, _sid}, %{assigns: %{flush: nil}} = socket),
    do: {:noreply, assign(socket, :flush, Process.send_after(self(), :pdt_flush, @flush_ms))}

  def handle_info({:pdt_event, _sid}, socket), do: {:noreply, socket}

  def handle_info(:pdt_flush, socket), do: {:noreply, socket |> cancel_flush() |> flush()}

  def handle_info({:pdt_session, _sid}, socket), do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Loading

  # (Re)builds the page from the Store: on mount and whenever the page changes.
  defp load(%{assigns: %{root: nil}} = socket), do: reset(socket, [], [])

  defp load(%{assigns: %{root: root}} = socket) do
    sids = Page.sids(root)
    socket = resubscribe(socket, sids)
    events = sids |> Enum.flat_map(&Store.events/1) |> Enum.sort_by(& &1.seq)
    reset(socket, sids, events)
  end

  defp reset(socket, sids, events) do
    socket
    |> assign(sids: sids, seqs: last_seqs(sids, events), summary: Summary.new(events))
    |> assign(:missing?, sids == [])
    |> stream(:queries, Enum.filter(events, &query?/1), reset: true, limit: -@dom_limit)
    |> stream(:requests, Enum.filter(events, &request?/1), reset: true, limit: -@dom_limit)
  end

  defp flush(%{assigns: %{sids: sids, seqs: seqs}} = socket) do
    events =
      sids
      |> Enum.flat_map(&Store.events(&1, Map.get(seqs, &1, 0)))
      |> Enum.sort_by(& &1.seq)

    Enum.reduce(events, socket, &insert/2)
    |> assign(:seqs, last_seqs(sids, events, seqs))
    |> assign(:summary, Enum.reduce(events, socket.assigns.summary, &Summary.add(&2, &1)))
  end

  defp insert(%Event{} = event, socket) do
    cond do
      query?(event) -> stream_insert(socket, :queries, event, limit: -@dom_limit)
      request?(event) -> stream_insert(socket, :requests, event, limit: -@dom_limit)
      true -> socket
    end
  end

  defp last_seqs(sids, events, initial \\ %{}) do
    Enum.reduce(events, Map.take(initial, sids), fn %Event{sid: sid, seq: seq}, acc ->
      Map.update(acc, sid, seq, &max(&1, seq))
    end)
  end

  # Subscriptions follow the page: the sids shown plus the root, whose
  # `{:pdt_session, _}` announces the first LiveView connection.
  defp resubscribe(socket, sids) do
    case connected?(socket) do
      true ->
        wanted = Enum.uniq([socket.assigns.root | sids])
        subscribed = socket.assigns.subscribed
        Enum.each(subscribed -- wanted, &Notify.unsubscribe/1)
        Enum.each(wanted -- subscribed, &Notify.subscribe/1)
        assign(socket, :subscribed, wanted)

      false ->
        socket
    end
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
      <header class="pdt-header">
        <span class="pdt-logo">dev toolbar</span>
        <.summary_bar summary={@summary} />
        <nav class="pdt-tabs" role="tablist">
          <button
            :for={{tab, label} <- [{"ecto", "Ecto"}, {"request", "Request"}]}
            id={"pdt-tab-" <> tab}
            type="button"
            role="tab"
            aria-selected={to_string(@tab == tab)}
            class={["pdt-tab", @tab == tab && "pdt-tab--active"]}
            phx-click="tab"
            phx-value-tab={tab}
          >
            {label}
          </button>
        </nav>
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

      <section id="pdt-section-ecto" class="pdt-section" hidden={@tab != "ecto"}>
        <ul id="pdt-queries" class="pdt-list" phx-update="stream">
          <li id="pdt-queries-empty" class="pdt-list__empty">No queries yet.</li>
          <.query_row :for={{id, event} <- @streams.queries} id={id} event={event} />
        </ul>
      </section>

      <section id="pdt-section-request" class="pdt-section" hidden={@tab != "request"}>
        <ul id="pdt-requests" class="pdt-list" phx-update="stream">
          <li id="pdt-requests-empty" class="pdt-list__empty">No requests yet.</li>
          <.request_row :for={{id, event} <- @streams.requests} id={id} event={event} />
        </ul>
      </section>
    </div>
    """
  end
end
