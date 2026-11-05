defmodule PhoenixDevToolbar.Panels.LiveView do
  @moduledoc false
  # Function components of the panel's LiveView tab (ADR 07): the profiler, the
  # assigns inspector, the server and client event log and the component tree,
  # as WAI-ARIA sub-tabs. Data comes from PanelLive; nothing here reads the Store.

  use Phoenix.Component

  import PhoenixDevToolbar.Components, only: [duration: 1]

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Profile

  @sub_tabs [
    {"profiler", "Profiler"},
    {"assigns", "Assigns"},
    {"events", "Events"},
    {"components", "Components"}
  ]

  @doc false
  @spec sub_tabs() :: [String.t()]
  def sub_tabs, do: Enum.map(@sub_tabs, &elem(&1, 0))

  attr :tab, :string, required: true
  attr :profile, Profile, required: true
  attr :snapshot, :any, required: true, doc: "nil, a Truncate.snapshot/1 or {:missing, why}"
  attr :snapshot_pending?, :boolean, required: true
  attr :last_changed, :list, required: true, doc: "keys changed by the last callback"
  attr :events, :any, required: true, doc: "the :lv_events stream"
  attr :root, :string, required: true

  def section(assigns) do
    assigns = assign(assigns, :sub_tabs, @sub_tabs)

    ~H"""
    <nav class="pdt-subtabs" role="tablist" aria-label="LiveView">
      <button
        :for={{tab, label} <- @sub_tabs}
        id={"pdt-lv-tab-" <> tab}
        type="button"
        role="tab"
        aria-selected={to_string(@tab == tab)}
        aria-controls={"pdt-lv-" <> tab}
        tabindex={if(@tab == tab, do: "0", else: "-1")}
        class={["pdt-subtab", @tab == tab && "pdt-subtab--active"]}
        phx-click="lv_tab"
        phx-value-tab={tab}
      >
        {label}
      </button>
    </nav>

    <div
      id="pdt-lv-profiler"
      role="tabpanel"
      aria-labelledby="pdt-lv-tab-profiler"
      hidden={@tab != "profiler"}
    >
      <.profiler profile={@profile} />
    </div>

    <div
      id="pdt-lv-assigns"
      role="tabpanel"
      aria-labelledby="pdt-lv-tab-assigns"
      hidden={@tab != "assigns"}
    >
      <.snapshot
        snapshot={@snapshot}
        pending?={@snapshot_pending?}
        last_changed={@last_changed}
      />
    </div>

    <div
      id="pdt-lv-events"
      role="tabpanel"
      aria-labelledby="pdt-lv-tab-events"
      hidden={@tab != "events"}
    >
      <ul id="pdt-lv-log" class="pdt-list" phx-update="stream">
        <li id="pdt-lv-log-empty" class="pdt-list__empty">No LiveView callbacks yet.</li>
        <.event_row :for={{id, event} <- @events} id={id} event={event} root={@root} />
      </ul>
    </div>

    <div
      id="pdt-lv-components"
      role="tabpanel"
      aria-labelledby="pdt-lv-tab-components"
      hidden={@tab != "components"}
    >
      <p class="pdt-empty">No components yet.</p>
    </div>
    """
  end

  attr :snapshot, :any, required: true
  attr :pending?, :boolean, required: true
  attr :last_changed, :list, required: true

  defp snapshot(assigns) do
    ~H"""
    <div class="pdt-snapshot-bar">
      <button id="pdt-snapshot-refresh" type="button" class="pdt-button" phx-click="lv_snapshot">
        Refresh
      </button>
      <span class="pdt-hint">
        {if(@pending?,
          do: "Reading…",
          else: "Values are truncated; highlighted: changed by the last callback."
        )}
      </span>
    </div>
    <%= case @snapshot do %>
      <% {:missing, :no_live_view} -> %>
        <p id="pdt-snapshot-missing" class="pdt-empty">No LiveView on this page.</p>
      <% {:missing, :gone} -> %>
        <p id="pdt-snapshot-missing" class="pdt-empty">
          The LiveView is not running anymore (it crashed or the page navigated away).
        </p>
      <% %{entries: entries, omitted: omitted} -> %>
        <dl id="pdt-snapshot" class="pdt-snapshot">
          <div
            :for={{key, value} <- entries}
            id={"pdt-snapshot-" <> key_name(key)}
            class={["pdt-snapshot__entry", key in @last_changed && "pdt-snapshot--changed"]}
          >
            <dt>{key_name(key)}</dt>
            <dd><code>{value}</code></dd>
          </div>
        </dl>
        <p :if={omitted > 0} class="pdt-hint pdt-snapshot__more">+{omitted} more assigns</p>
      <% nil -> %>
        <p class="pdt-empty">No snapshot yet.</p>
    <% end %>
    """
  end

  attr :profile, Profile, required: true

  defp profiler(assigns) do
    assigns = assign(assigns, :rows, Profile.rows(assigns.profile))

    ~H"""
    <p :if={@rows == []} class="pdt-empty">No LiveView callbacks yet.</p>
    <table :if={@rows != []} id="pdt-profiler-table" class="pdt-table">
      <thead>
        <tr>
          <th scope="col">Callback</th>
          <th scope="col" class="pdt-num">Count</th>
          <th scope="col" class="pdt-num">Total</th>
          <th scope="col" class="pdt-num">Avg</th>
          <th scope="col" class="pdt-num">Max</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={{row, index} <- Enum.with_index(@rows)} id={"pdt-profile-#{index}"}>
          <td><code>{label(row.key)}</code></td>
          <td class="pdt-num pdt-count">{row.count}</td>
          <td class="pdt-num">{duration(row.total_us)}</td>
          <td class="pdt-num">{duration(div(row.total_us, max(row.count, 1)))}</td>
          <td class="pdt-num">{duration(row.max_us)}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :id, :string, required: true
  attr :event, Event, required: true
  attr :root, :string, required: true

  defp event_row(%{event: %Event{kind: :callback}} = assigns) do
    ~H"""
    <li id={@id} class={["pdt-row", @event.data.error && "pdt-row--error"]}>
      <div class="pdt-row__head">
        <code>{label(@event.data)}</code>
        <span class="pdt-time">{duration(@event.duration)}</span>
      </div>
      <div class="pdt-row__meta">
        <.phase_tag event={@event} root={@root} />
        <.changed changes={@event.data.changes} />
        <.pushed pushed={@event.data.pushed} />
      </div>
      <pre :if={@event.data.error} class="pdt-error">{@event.data.error}</pre>
      <details :if={details?(@event.data)} class="pdt-details">
        <summary>details</summary>
        <dl>
          <%= if @event.data.params do %>
            <dt>params</dt>
            <dd><code>{@event.data.params}</code></dd>
          <% end %>
          <%= for {key, value} <- changed_values(@event.data.changes) do %>
            <dt>{key_name(key)}</dt>
            <dd><code>{value}</code></dd>
          <% end %>
        </dl>
      </details>
    </li>
    """
  end

  defp event_row(%{event: %Event{kind: :render}} = assigns) do
    ~H"""
    <li id={@id} class={["pdt-row", @event.data.error && "pdt-row--error"]}>
      <div class="pdt-row__head">
        <code>{render_label(@event.data)}</code>
        <span class="pdt-time">{duration(@event.duration)}</span>
      </div>
      <div class="pdt-row__meta">
        <.phase_tag event={@event} root={@root} />
        <span :if={@event.data.id} class="pdt-tag" title="Component id">id {@event.data.id}</span>
        <span :if={@event.data.force?} class="pdt-tag" title="Forced render">forced</span>
      </div>
      <pre :if={@event.data.error} class="pdt-error">{@event.data.error}</pre>
    </li>
    """
  end

  attr :event, Event, required: true
  attr :root, :string, required: true

  defp phase_tag(%{event: %Event{sid: sid}, root: sid} = assigns) do
    ~H"""
    <span class="pdt-tag pdt-tag--http" title="Ran during the HTTP request (dead render)">HTTP</span>
    """
  end

  defp phase_tag(assigns) do
    ~H"""
    <span class="pdt-tag pdt-tag--live" title="Ran in the connected LiveView">live</span>
    """
  end

  attr :changes, :map, default: nil

  defp changed(%{changes: %{keys: _}} = assigns) do
    ~H"""
    <span :for={key <- @changes.keys} class="pdt-tag pdt-changed" title="Assign changed">
      {key_name(key)}
    </span>
    <span :if={@changes.omitted > 0} class="pdt-tag pdt-changed">+{@changes.omitted} more</span>
    """
  end

  defp changed(assigns), do: ~H""

  attr :pushed, :any, default: nil

  defp pushed(%{pushed: :unavailable} = assigns) do
    ~H"""
    <span
      class="pdt-tag pdt-pushed"
      title="This LiveView version stores pushed events differently: see the server log"
    >
      push_event names unavailable
    </span>
    """
  end

  defp pushed(%{pushed: [_ | _]} = assigns) do
    ~H"""
    <span :for={name <- @pushed} class="pdt-tag pdt-pushed" title="push_event">⇢ {name}</span>
    """
  end

  defp pushed(assigns), do: ~H""

  defp details?(%{params: params}) when is_binary(params), do: true
  defp details?(%{changes: %{values: values}}) when map_size(values) > 0, do: true
  defp details?(_data), do: false

  defp changed_values(%{keys: keys, values: values}),
    do: for(key <- keys, value = Map.get(values, key), do: {key, value})

  defp changed_values(_changes), do: []

  @doc false
  @spec label(Profile.key() | map()) :: String.t()
  def label(:other), do: "other"
  def label({:render, component, nil}), do: render_label(%{component: component})

  def label({callback, subject, event}),
    do: label(%{callback: callback, component: subject, event: event})

  def label(%{callback: callback, event: event} = data) do
    subject = Profile.subject(data)

    [subject && short(subject), Atom.to_string(callback), event && inspect(event)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp render_label(%{component: nil}), do: "render"
  defp render_label(%{component: component}), do: short(component) <> " render"

  defp short(module) when is_atom(module), do: inspect(module)

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key), do: inspect(key)
end
