defmodule PhoenixDevToolbar.Components do
  @moduledoc false
  # Function components of the panel. Classes are `pdt-` prefixed and styled by
  # priv/static/panel.css; the panel lives in its own iframe (ADR 04).

  use Phoenix.Component

  alias PhoenixDevToolbar.Event

  attr :badges, :list,
    required: true,
    doc: "the plugins' badges (PhoenixDevToolbar.Plugin.badge())"

  attr :dropped, :integer, default: 0, doc: "events over the flood guard budget, not recorded"

  attr :trimmed, :integer,
    default: 0,
    doc: "oldest events removed past the per plugin and per session caps"

  def summary_bar(assigns) do
    ~H"""
    <div id="pdt-summary" class="pdt-summary">
      <span
        :for={badge <- @badges}
        id={"pdt-badge-" <> badge.id}
        class={["pdt-badge", level_class(badge.level)]}
        title={badge[:title]}
      >
        {badge.text}
      </span>
      <span
        :if={@dropped > 0}
        id="pdt-badge-dropped"
        class="pdt-badge pdt-badge--warn"
        title="Events over the per second limit were not recorded: counts are lower than reality"
      >
        +{@dropped} dropped
      </span>
      <span
        :if={@trimmed > 0}
        id="pdt-badge-trimmed"
        class="pdt-badge pdt-badge--warn"
        title="The oldest events were removed past the per session limits: lists start later than the page"
      >
        {@trimmed} older trimmed
      </span>
    </div>
    """
  end

  defp level_class(:ok), do: "pdt-badge--ok"
  defp level_class(:warn), do: "pdt-badge--warn"
  defp level_class(:error), do: "pdt-badge--error"
  defp level_class(_info), do: nil

  attr :id, :string, required: true
  attr :event, Event, required: true
  attr :root, :string, required: true, doc: "the request sid: its events ran in the dead render"

  def query_row(assigns) do
    ~H"""
    <li id={@id} class={["pdt-row", failed?(@event) && "pdt-row--error"]}>
      <div class="pdt-row__head">
        <code class="pdt-sql">{@event.data.sql}</code>
        <span class="pdt-time" title={times_title(@event.data.times)}>{duration(@event.duration)}</span>
      </div>
      <div class="pdt-row__meta">
        <.phase_tag sid={@event.sid} root={@root} />
        <span :if={@event.data.source} class="pdt-tag">{@event.data.source}</span>
        <span class="pdt-tag">{result(@event.data.result)}</span>
        <span :if={@event.data.caller?} class="pdt-tag" title="Run by a Task.async child of the page">task</span>
        <span
          :if={@event.data[:n_plus_one?]}
          class="pdt-tag pdt-tag--warn"
          title="Repeated in this callback: listed above the queries"
        >
          N+1
        </span>
        <span :if={origin(@event)} class="pdt-origin">{origin(@event)}</span>
      </div>
      <details class="pdt-details">
        <summary>details</summary>
        <dl>
          <dt>params</dt>
          <dd><code>{@event.data.params}</code></dd>
          <dt>repo</dt>
          <dd><code>{inspect(@event.data.repo)}</code></dd>
          <dt>timings</dt>
          <dd class="pdt-timings">
            <span :for={{key, us} <- timings(@event.data.times)}>{key} {duration(us)}</span>
          </dd>
          <dt>origin</dt>
          <dd :if={@event.data.stacktrace != []}>
            <pre>{Enum.join(@event.data.stacktrace, "\n")}</pre>
          </dd>
          <dd :if={@event.data.stacktrace == []} class="pdt-hint">
            Unknown: set <code>stacktrace: true</code>
            in your repo config to see where queries come from.
          </dd>
        </dl>
      </details>
    </li>
    """
  end

  attr :groups, :list, required: true, doc: "PhoenixDevToolbar.NPlusOne.groups/1"
  attr :detected, :integer, required: true, doc: "how many groups were detected in total"
  attr :root, :string, required: true

  @doc "The N+1 groups detected on the page, newest first (ADR 08)."
  def n_plus_one_list(assigns) do
    ~H"""
    <section id="pdt-n-plus-one" class="pdt-n-plus-one" aria-label="N+1 queries">
      <h3 class="pdt-n-plus-one__title">
        N+1: {@detected} repeated {noun_queries(@detected)}
      </h3>
      <ul class="pdt-list">
        <li :for={group <- @groups} id={"pdt-n-plus-one-#{group.seq}"} class="pdt-row">
          <div class="pdt-row__head">
            <code class="pdt-sql">{group.sql}</code>
            <span class="pdt-badge pdt-badge--warn" title={"Ran #{group.count} times in one callback"}>
              <span aria-hidden="true">×{group.count}</span>
              <span class="pdt-sr-only">{group.count} times</span>
            </span>
          </div>
          <div class="pdt-row__meta">
            <.phase_tag sid={group.sid} root={@root} />
            <span :if={group.origin} class="pdt-origin">{group.origin}</span>
          </div>
        </li>
      </ul>
      <p :if={Enum.any?(@groups, &is_nil(&1.origin))} id="pdt-n-plus-one-hint" class="pdt-hint">
        Without origins, queries are grouped by SQL alone: set <code>stacktrace: true</code>
        in your repo config to tell call sites apart.
      </p>
    </section>
    """
  end

  defp noun_queries(1), do: "query"
  defp noun_queries(_count), do: "queries"

  attr :sid, :string, required: true
  attr :root, :string, required: true

  defp phase_tag(%{sid: sid, root: sid} = assigns) do
    ~H"""
    <span class="pdt-tag pdt-tag--http" title="Ran during the HTTP request (dead render)">HTTP</span>
    """
  end

  defp phase_tag(assigns) do
    ~H"""
    <span class="pdt-tag pdt-tag--live" title="Ran in the connected LiveView">live</span>
    """
  end

  attr :id, :string, required: true
  attr :event, Event, required: true

  def request_row(%{event: %Event{kind: :response}} = assigns) do
    ~H"""
    <li id={@id} class="pdt-row">
      <div class="pdt-row__head">
        <span class="pdt-method">{@event.data.method}</span>
        <code>{@event.data.path}</code>
        <span class={["pdt-badge", status_class(@event.data.status)]}>{@event.data.status}</span>
        <span class="pdt-time">{duration(@event.duration)}</span>
      </div>
      <div class="pdt-row__meta">
        <span class="pdt-tag">response</span>
        <span :if={@event.data.content_type} class="pdt-tag">{@event.data.content_type}</span>
      </div>
    </li>
    """
  end

  def request_row(assigns) do
    ~H"""
    <li id={@id} class={["pdt-row", @event.kind == :exception && "pdt-row--error"]}>
      <div class="pdt-row__head">
        <span class="pdt-method">{@event.data.method}</span>
        <code>{@event.data.route}</code>
        <span :if={@event.data.status} class={["pdt-badge", status_class(@event.data.status)]}>
          {@event.data.status}
        </span>
        <span class="pdt-time">{duration(@event.duration)}</span>
      </div>
      <div class="pdt-row__meta">
        <span class="pdt-tag">{if(@event.kind == :exception, do: "exception", else: "router")}</span>
        <code :if={@event.data.handler} class="pdt-origin">{@event.data.handler}</code>
      </div>
      <pre :if={@event.kind == :exception} class="pdt-error">{Map.get(@event.data, :error)}</pre>
    </li>
    """
  end

  @doc """
  Formats a duration in microseconds.

      iex> PhoenixDevToolbar.Components.duration(nil)
      "n/a"

      iex> PhoenixDevToolbar.Components.duration(42)
      "0.04 ms"

      iex> PhoenixDevToolbar.Components.duration(12_345)
      "12.3 ms"

      iex> PhoenixDevToolbar.Components.duration(2_500_000)
      "2.50 s"

  """
  @spec duration(non_neg_integer() | nil) :: String.t()
  def duration(nil), do: "n/a"

  def duration(us) when us >= 1_000_000,
    do: :erlang.float_to_binary(us / 1_000_000, decimals: 2) <> " s"

  def duration(us) when us >= 10_000, do: :erlang.float_to_binary(us / 1000, decimals: 1) <> " ms"
  def duration(us), do: :erlang.float_to_binary(us / 1000, decimals: 2) <> " ms"

  defp status_class(status) when is_integer(status) and status >= 500, do: "pdt-badge--error"
  defp status_class(status) when is_integer(status) and status >= 400, do: "pdt-badge--warn"
  defp status_class(_status), do: "pdt-badge--ok"

  defp failed?(%Event{data: %{result: {:error, _}}}), do: true
  defp failed?(_event), do: false

  defp result({:ok, nil}), do: "ok"
  defp result({:ok, 1}), do: "1 row"
  defp result({:ok, rows}), do: "#{rows} rows"
  defp result({:error, message}), do: "error: " <> message
  defp result(nil), do: "n/a"

  defp origin(%Event{data: %{stacktrace: [first | _]}}), do: first
  defp origin(_event), do: nil

  defp times_title(times) do
    Enum.map_join(timings(times), ", ", fn {key, us} -> "#{key}: #{duration(us)}" end)
  end

  # Ecto's timings in a stable, readable order: where the time went.
  @timing_labels [
    queue_time: "queue",
    query_time: "query",
    decode_time: "decode",
    idle_time: "idle"
  ]

  @doc """
  Orders and labels the Ecto timings of a query, skipping missing ones.

      iex> PhoenixDevToolbar.Components.timings(%{query_time: 30, queue_time: 5, total_time: 35})
      [{"queue", 5}, {"query", 30}]

  """
  @spec timings(map()) :: [{String.t(), non_neg_integer()}]
  def timings(times) do
    for {key, label} <- @timing_labels, us = times[key], do: {label, us}
  end
end
