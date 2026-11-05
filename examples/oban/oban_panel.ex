defmodule PdtExamples.ObanPanel do
  @moduledoc """
  The tab of `PdtExamples.Oban`: the page's job inserts, oldest first, in a
  stream (a page can enqueue thousands).
  """

  use PhoenixDevToolbar.Panel

  alias PhoenixDevToolbar.Panel

  @dom_limit 500

  @impl Phoenix.LiveComponent
  def mount(socket), do: {:ok, stream_configure(socket, :jobs, dom_id: &"oban-job-#{&1.seq}")}

  @impl Panel
  def handle_reset(events, socket),
    do: stream(socket, :jobs, events, reset: true, limit: -@dom_limit)

  @impl Panel
  def handle_events(events, socket),
    do: Enum.reduce(events, socket, &stream_insert(&2, :jobs, &1, limit: -@dom_limit))

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <ul id="oban-jobs" class="pdt-list" phx-update="stream">
      <li id="oban-jobs-empty" class="pdt-list__empty">No jobs enqueued by this page.</li>
      <li
        :for={{id, event} <- @streams.jobs}
        id={id}
        class={["pdt-row", event.kind in [:failed, :rejected] && "pdt-row--error"]}
      >
        <.job event={event} />
      </li>
    </ul>
    """
  end

  defp job(%{event: %{kind: :inserted}} = assigns) do
    ~H"""
    <div class="pdt-row__head">
      <code>{@event.data.worker}</code>
      <span class="pdt-time">{Panel.duration(@event.duration)}</span>
    </div>
    <div class="pdt-row__meta">
      <span class="pdt-tag">{@event.data.queue}</span>
      <span class="pdt-tag">{@event.data.state}</span>
      <span :if={@event.data.conflict?} class="pdt-tag" title="A unique job already existed">duplicate</span>
      <code class="pdt-origin">{@event.data.args}</code>
    </div>
    """
  end

  defp job(%{event: %{kind: :inserted_all}} = assigns) do
    ~H"""
    <div class="pdt-row__head">
      <code>insert_all: {@event.data.count} jobs</code>
      <span class="pdt-time">{Panel.duration(@event.duration)}</span>
    </div>
    <div class="pdt-row__meta">
      <span :for={worker <- @event.data.workers} class="pdt-tag">{worker}</span>
    </div>
    """
  end

  defp job(%{event: %{kind: :failed}} = assigns) do
    ~H"""
    <div class="pdt-row__head"><code>insert raised</code></div>
    <pre class="pdt-error">{@event.data.error}</pre>
    """
  end

  defp job(assigns) do
    ~H"""
    <div class="pdt-row__head"><code>insert rejected (invalid changeset)</code></div>
    """
  end
end
