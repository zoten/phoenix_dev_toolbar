defmodule PhoenixDevToolbar.Components do
  @moduledoc false
  # Function components of the panel. Classes are `pdt-` prefixed and styled by
  # priv/static/panel.css; the panel lives in its own iframe (ADR 04).

  use Phoenix.Component

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Explain
  alias PhoenixDevToolbar.QueryFrames

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
        data-pdt-level={badge.level}
        title={badge[:title]}
      >
        {badge.text}<span :if={badge[:title]} class="pdt-sr-only">: {badge[:title]}</span>
      </span>
      <span
        :if={@dropped > 0}
        id="pdt-badge-dropped"
        class="pdt-badge pdt-badge--warn"
        data-pdt-level="warn"
        title="Events over the per second limit were not recorded: counts are lower than reality"
      >
        +{@dropped} dropped<span class="pdt-sr-only">: Events over the per second limit were not recorded: counts are lower than reality</span>
      </span>
      <span
        :if={@trimmed > 0}
        id="pdt-badge-trimmed"
        class="pdt-badge pdt-badge--warn"
        data-pdt-level="warn"
        title="The oldest events were removed past the per session limits: lists start later than the page"
      >
        {@trimmed} older trimmed<span class="pdt-sr-only">: The oldest events were removed past the per session limits: lists start later than the page</span>
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
  attr :target, :any, default: nil, doc: "the Ecto tab component, for the EXPLAIN button"

  def query_row(assigns) do
    assigns = assign(assigns, :noise, QueryFrames.noise(assigns.event.data))

    ~H"""
    <li
      id={@id}
      class={["pdt-row", failed?(@event) && "pdt-row--error", @noise && "pdt-row--noise"]}
      {row_attrs("query", @event,
        "data-pdt-source": @event.data.source,
        "data-pdt-error": failed?(@event),
        "data-pdt-n-plus-one": @event.data[:n_plus_one?] == true,
        "data-pdt-noise": @noise
      )}
    >
      <div class="pdt-row__head">
        <code class="pdt-sql">{@event.data.sql}</code>
        <span class="pdt-time" title={times_title(@event.data.times)}>{duration(@event.duration)}</span>
      </div>
      <div class="pdt-row__meta">
        <.phase_tag sid={@event.sid} root={@root} />
        <span :if={@event.data.source} class="pdt-tag">{@event.data.source}</span>
        <span class="pdt-tag">{result(@event.data.result)}</span>
        <span :if={@event.data.caller?} class="pdt-tag" title="Run by a Task.async child of the page">task<span class="pdt-sr-only">: Run by a Task.async child of the page</span></span>
        <span
          :if={@noise}
          id={"pdt-noise-#{@event.seq}"}
          class="pdt-tag"
          title="A framework query (such as Phoenix.Ecto.CheckRepoStatus, run on every dev request): left out of the query count"
        >
          framework<span class="pdt-sr-only">: A framework query (such as Phoenix.Ecto.CheckRepoStatus, run on every dev request): left out of the query count</span>
        </span>
        <span
          :if={@event.data[:n_plus_one?]}
          class="pdt-tag pdt-tag--warn"
          title="Repeated in one callback (or between two callbacks): see the N+1 list above"
        >
          N+1<span class="pdt-sr-only">: Repeated in one callback (or between two callbacks): see the N+1 list above</span>
        </span>
        <span :if={origin(@event)} class="pdt-origin">{origin(@event)}</span>
        <button
          :if={@target && Explain.explainable?(@event)}
          id={"pdt-explain-#{@event.seq}"}
          type="button"
          class="pdt-button pdt-button--small"
          phx-click="explain"
          phx-value-seq={@event.seq}
          phx-target={@target}
          aria-label={"EXPLAIN query #{@event.seq}" <> on_source(@event)}
          data-pdt-keep-focus
          aria-busy={to_string(@event.data[:plan] == :running)}
        >
          {if(@event.data[:plan] == :running, do: "explaining…", else: "EXPLAIN")}
        </button>
      </div>
      <.plan
        :if={@event.data[:plan] not in [nil, :running]}
        seq={@event.seq}
        plan={@event.data.plan}
        target={@target}
      />
      <div id={"pdt-details-#{@event.seq}"} class="pdt-details">
        <button
          id={"pdt-details-toggle-#{@event.seq}"}
          type="button"
          class="pdt-details__toggle"
          phx-click="toggle_details"
          phx-value-seq={@event.seq}
          phx-target={@target}
          aria-expanded={to_string(@event.data[:open?] == true)}
          aria-label={"Details of query #{@event.seq}" <> on_source(@event)}
          data-pdt-keep-focus
        >
          details
        </button>
        <dl :if={@event.data[:open?] == true}>
          <dt>params</dt>
          <dd><code>{@event.data.params}</code></dd>
          <dt>repo</dt>
          <dd><code>{inspect(@event.data.repo)}</code></dd>
          <dt>timings</dt>
          <dd id={"pdt-timings-#{@event.seq}"} class="pdt-timings">
            <span :for={{key, us} <- timings(@event.data.times)}>{key} {duration(us)}</span>
          </dd>
          <dt :if={not Explain.explainable?(@event)}>explain</dt>
          <dd :if={not Explain.explainable?(@event)} class="pdt-hint">
            {Explain.unexplainable_reason(@event)}
          </dd>
          <dt>origin</dt>
          <dd :if={@event.data.stacktrace != []}>
            <pre>{Enum.join(@event.data.stacktrace, "\n")}</pre>
          </dd>
          <dd
            :if={@event.data.stacktrace == []}
            id={"pdt-stacktrace-hint-#{@event.seq}"}
            class="pdt-hint"
          >
            Unknown: set <code>stacktrace: true</code>
            in your repo config to see where queries come from.
          </dd>
        </dl>
      </div>
    </li>
    """
  end

  attr :seq, :integer, required: true
  attr :plan, :any, required: true, doc: "{:ok, text} or {:error, reason}"
  attr :target, :any, required: true

  defp plan(%{plan: {:ok, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <div id={"pdt-plan-#{@seq}"} class="pdt-plan" role="region" aria-label={"Plan of query #{@seq}"}>
      <button
        id={"pdt-plan-hide-#{@seq}"}
        type="button"
        class="pdt-button pdt-button--small pdt-plan__hide"
        phx-click="hide_plan"
        phx-value-seq={@seq}
        phx-target={@target}
        aria-label={"Hide the plan of query #{@seq}"}
        data-pdt-keep-focus={"pdt-explain-#{@seq}"}
      >
        Hide
      </button>
      <pre>{@text}</pre>
    </div>
    """
  end

  defp plan(%{plan: {:error, reason}} = assigns) do
    assigns = assign(assigns, :reason, PhoenixDevToolbar.Explain.reason(reason))

    ~H"""
    <p id={"pdt-plan-#{@seq}"} class="pdt-error" role="alert">EXPLAIN failed: {@reason}</p>
    """
  end

  defp on_source(%Event{data: %{source: source}}) when is_binary(source), do: " on " <> source
  defp on_source(_event), do: ""

  attr :groups, :list, required: true, doc: "PhoenixDevToolbar.NPlusOne.groups/1"
  attr :detected, :integer, required: true, doc: "how many distinct groups were detected"
  attr :root, :string, required: true
  attr :target, :any, default: nil, doc: "the Ecto tab component, for the Clear button"

  @doc "The N+1 groups detected on the page, most recent first (ADR 08)."
  def n_plus_one_list(assigns) do
    ~H"""
    <section id="pdt-n-plus-one" class="pdt-n-plus-one" aria-labelledby="pdt-n-plus-one-title">
      <div class="pdt-n-plus-one__head">
        <h3 id="pdt-n-plus-one-title" class="pdt-n-plus-one__title">
          N+1: {@detected} repeated {noun_queries(@detected)}
        </h3>
        <button
          :if={@target}
          id="pdt-n-plus-one-clear"
          type="button"
          class="pdt-button pdt-button--small"
          phx-click="clear_n_plus_one"
          phx-target={@target}
          title="Forget these groups: after a fix, see whether they come back"
        >
          Clear
        </button>
      </div>
      <ul class="pdt-list">
        <li
          :for={group <- @groups}
          id={"pdt-n-plus-one-#{group.seq}"}
          class="pdt-row"
          data-pdt-row="n-plus-one"
          data-pdt-count={group.count}
          data-pdt-callbacks={group.callbacks}
        >
          <div class="pdt-row__head">
            <code class="pdt-sql">{group.sql}</code>
            <span
              class="pdt-badge pdt-badge--warn"
              title={"Up to #{group.count} times in one callback"}
            >
              <span aria-hidden="true">×{group.count}</span>
              <span class="pdt-sr-only">up to {group.count} times in one callback</span>
            </span>
          </div>
          <div class="pdt-row__meta">
            <.phase_tag :for={sid <- Enum.reverse(group.sids)} sid={sid} root={@root} />
            <span class="pdt-tag" title="Callbacks where it repeated">
              in {group.callbacks} {noun_callbacks(group.callbacks)}
            </span>
            <span :if={group.at} class="pdt-time" title="Last time it repeated">
              last {clock(group.at)}
            </span>
            <span :if={group.origin} class="pdt-origin" data-pdt-origin>{group.origin}</span>
          </div>
        </li>
      </ul>
      <p id="pdt-n-plus-one-advice" class="pdt-hint">
        The same query, once per row: load the data in one query instead, with <code>Repo.preload/2</code>, a
        <code>preload:</code>
        in the query or a join.
      </p>
      <p :if={Enum.any?(@groups, &is_nil(&1.origin))} id="pdt-n-plus-one-hint" class="pdt-hint">
        Without origins, queries are grouped by SQL alone: set <code>stacktrace: true</code>
        in your repo config to tell call sites apart.
      </p>
    </section>
    """
  end

  defp noun_callbacks(1), do: "callback"
  defp noun_callbacks(_count), do: "callbacks"

  # The server's local time (the developer's machine, in dev).
  defp clock(at_us) do
    {_date, {h, m, s}} = :calendar.system_time_to_local_time(at_us, :microsecond)
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary()
  end

  defp noun_queries(1), do: "query"
  defp noun_queries(_count), do: "queries"

  attr :sid, :string, required: true
  attr :root, :string, required: true

  defp phase_tag(%{sid: sid, root: sid} = assigns) do
    ~H"""
    <span
      class="pdt-tag pdt-tag--http"
      data-pdt-phase="http"
      title="Ran during the HTTP request (dead render)"
    >
      HTTP<span class="pdt-sr-only">: Ran during the HTTP request (dead render)</span>
    </span>
    """
  end

  defp phase_tag(assigns) do
    ~H"""
    <span class="pdt-tag pdt-tag--live" data-pdt-phase="live" title="Ran in the connected LiveView">
      live<span class="pdt-sr-only">: Ran in the connected LiveView</span>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :event, Event, required: true

  def request_row(%{event: %Event{kind: :response}} = assigns) do
    ~H"""
    <li id={@id} class="pdt-row" {request_attrs(@event)}>
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
    <li
      id={@id}
      class={["pdt-row", @event.kind == :exception && "pdt-row--error"]}
      {request_attrs(@event)}
    >
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
      <.stack_args :if={@event.kind == :exception} data={@event.data} />
    </li>
    """
  end

  @doc """
  The call arguments of a crash's frames (`stack_args:`, ADR 03), under its
  banner: one `frame` and its arguments per frame that carried them. Renders
  nothing when the event has none (the default).
  """
  attr :data, :map, required: true

  def stack_args(assigns) do
    assigns = assign(assigns, :frames, stack_arg_frames(assigns.data))

    ~H"""
    <details :if={@frames != []} class="pdt-details pdt-stack-args" data-pdt-stack-args>
      <summary>call arguments</summary>
      <dl>
        <%= for {frame, args} <- @frames do %>
          <dt><code>{frame}</code></dt>
          <dd><code>{args}</code></dd>
        <% end %>
      </dl>
    </details>
    """
  end

  defp stack_arg_frames(%{stack_args: args, stacktrace: frames})
       when is_list(args) and is_list(frames) do
    for {frame, arg} when is_binary(arg) <- Enum.zip(frames, args), do: {frame, arg}
  end

  defp stack_arg_frames(_data), do: []

  @doc """
  Formats a byte count: `"512 B"`, `"1.5 KB"`, `"2.3 MB"`, `"1.1 GB"`.

      iex> PhoenixDevToolbar.Components.bytes(1536)
      "1.5 KB"

  """
  @spec bytes(non_neg_integer()) :: String.t()
  def bytes(n) when n >= 1_073_741_824, do: decimal(n / 1_073_741_824) <> " GB"
  def bytes(n) when n >= 1_048_576, do: decimal(n / 1_048_576) <> " MB"
  def bytes(n) when n >= 1024, do: decimal(n / 1024) <> " KB"
  def bytes(n), do: "#{n} B"

  defp decimal(value), do: :erlang.float_to_binary(value, decimals: 1)

  attr :values, :list, required: true, doc: "numbers, oldest first"
  attr :label, :string, required: true, doc: "what the line shows, for screen readers"

  @doc "A small inline SVG line of `values`, scaled to their own max."
  def sparkline(assigns) do
    assigns = assign(assigns, :points, sparkline_points(assigns.values))

    ~H"""
    <svg
      class="pdt-sparkline"
      viewBox="0 0 120 24"
      preserveAspectRatio="none"
      role="img"
      aria-label={@label}
    >
      <polyline :if={@points != ""} points={@points} fill="none" />
    </svg>
    """
  end

  defp sparkline_points([]), do: ""
  defp sparkline_points([_one]), do: ""

  defp sparkline_points(values) do
    max = max(Enum.max(values), 1)
    step = 120 / (length(values) - 1)

    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {value, index} ->
      x = Float.round(index * step, 1)
      y = Float.round(22 - value / max * 20, 1)
      "#{x},#{y}"
    end)
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

  @doc """
  The `data-pdt-*` attributes of a row showing one event (ADR 14): a contract
  for agents reading the panel, with raw values. `extra` attributes that are
  nil or false are left out, true ones are written bare.
  """
  @spec row_attrs(String.t(), Event.t(), keyword()) :: keyword()
  def row_attrs(row, %Event{} = event, extra \\ []) do
    [
      "data-pdt-row": row,
      "data-pdt-sid": event.sid,
      "data-pdt-seq": event.seq,
      "data-pdt-duration-us": event.duration
    ] ++ extra
  end

  defp request_attrs(%Event{} = event) do
    row_attrs("request", event,
      "data-pdt-kind": Atom.to_string(event.kind),
      "data-pdt-method": event.data[:method],
      "data-pdt-status": event.data[:status],
      "data-pdt-error": event.kind == :exception
    )
  end

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
