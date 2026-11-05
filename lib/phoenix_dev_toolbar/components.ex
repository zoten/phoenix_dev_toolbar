defmodule PhoenixDevToolbar.Components do
  @moduledoc false
  # Function components of the panel. Classes are `pdt-` prefixed and styled by
  # priv/static/panel.css; the panel lives in its own iframe (ADR 04).

  use Phoenix.Component

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Summary

  attr :summary, Summary, required: true

  def summary_bar(assigns) do
    ~H"""
    <div id="pdt-summary" class="pdt-summary">
      <span
        :if={@summary.response}
        id="pdt-badge-response"
        class={["pdt-badge", status_class(@summary.response.status)]}
      >
        {@summary.response.status} · {duration(@summary.response.duration)}
      </span>
      <span
        id="pdt-badge-queries"
        class={["pdt-badge", @summary.failed_queries > 0 && "pdt-badge--error"]}
      >
        {@summary.queries} {if(@summary.queries == 1, do: "query", else: "queries")} · {duration(
          @summary.db_us
        )}
      </span>
      <span :if={@summary.errors > 0} id="pdt-badge-errors" class="pdt-badge pdt-badge--error">
        {@summary.errors} {if(@summary.errors == 1, do: "error", else: "errors")}
      </span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :event, Event, required: true

  def query_row(assigns) do
    ~H"""
    <li id={@id} class={["pdt-row", failed?(@event) && "pdt-row--error"]}>
      <div class="pdt-row__head">
        <code class="pdt-sql">{@event.data.sql}</code>
        <span class="pdt-time" title={times_title(@event.data.times)}>{duration(@event.duration)}</span>
      </div>
      <div class="pdt-row__meta">
        <span :if={@event.data.source} class="pdt-tag">{@event.data.source}</span>
        <span class="pdt-tag">{result(@event.data.result)}</span>
        <span :if={@event.data.caller?} class="pdt-tag" title="Run by a Task.async child of the page">task</span>
        <span :if={origin(@event)} class="pdt-origin">{origin(@event)}</span>
      </div>
      <details class="pdt-details">
        <summary>details</summary>
        <dl>
          <dt>params</dt>
          <dd><code>{@event.data.params}</code></dd>
          <dt>repo</dt>
          <dd><code>{inspect(@event.data.repo)}</code></dd>
          <dt :if={@event.data.stacktrace != []}>stacktrace</dt>
          <dd :if={@event.data.stacktrace != []}>
            <pre>{Enum.join(@event.data.stacktrace, "\n")}</pre>
          </dd>
        </dl>
      </details>
    </li>
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
    Enum.map_join(times, ", ", fn {key, us} -> "#{key}: #{duration(us)}" end)
  end
end
