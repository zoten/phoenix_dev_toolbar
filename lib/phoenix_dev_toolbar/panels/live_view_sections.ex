defmodule PhoenixDevToolbar.Panels.LiveViewSections do
  @moduledoc false
  # Function components of the panel's LiveView tab (ADR 07): the profiler, the
  # assigns inspector, the server and client event log and the component tree,
  # as WAI-ARIA sub-tabs. Data comes from Panels.LiveView; nothing here reads
  # the Store.

  use Phoenix.Component

  import PhoenixDevToolbar.Components, only: [duration: 1, row_attrs: 3, stack_args: 1]

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Inspected
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

  @doc false
  # True when a tree row is the inspected element: the view's own row (no cid) or
  # a component of that view.
  @spec selected_in?([map()], Inspected.t() | nil) :: boolean()
  def selected_in?(views, %Inspected{root: root} = inspected) when is_binary(root),
    do: Enum.any?(views, &(selected_view?(&1, inspected) or selected_cid?(&1, inspected)))

  def selected_in?(_views, _inspected), do: false

  defp selected_view?(%{root: root}, %Inspected{root: root, cid: nil}) when is_binary(root),
    do: true

  defp selected_view?(_view, _inspected), do: false

  defp selected_cid?(%{root: root, components: components}, %Inspected{root: root, cid: cid})
       when is_binary(root) and is_integer(cid),
       do: cid_in?(components, cid)

  defp selected_cid?(_view, _inspected), do: false

  defp cid_in?(nodes, cid),
    do: Enum.any?(nodes, &(&1.cid == cid or cid_in?(&1.children, cid)))

  defp current(true), do: "true"
  defp current(false), do: nil

  attr :tab, :string, required: true
  attr :profile, Profile, required: true
  attr :snapshot, :any, required: true, doc: "nil, a Truncate.snapshot/1 or {:missing, why}"
  attr :snapshot_pending?, :boolean, required: true
  attr :last_changed, :list, required: true, doc: "keys changed by the last callback"
  attr :tree, :any, required: true, doc: "nil, a ComponentTree.t() or {:missing, why}"
  attr :polling?, :boolean, required: true
  attr :tree_pending?, :boolean, required: true
  attr :client_dropped, :integer, required: true
  attr :events, :any, required: true, doc: "the :lv_events stream"
  attr :root, :string, required: true
  attr :inspected, :any, required: true, doc: "nil or the Inspected element (ADR 16)"
  attr :editor, :any, default: nil, doc: "{PLUG_EDITOR template, cwd}, nil when unset"
  attr :target, :any, required: true, doc: "the LiveView panel component (@myself)"

  def section(assigns) do
    assigns = assign(assigns, :sub_tabs, @sub_tabs)

    ~H"""
    <.inspected_strip :if={@inspected} inspected={@inspected} editor={@editor} />
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
        phx-target={@target}
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
        target={@target}
      />
    </div>

    <div
      id="pdt-lv-events"
      role="tabpanel"
      aria-labelledby="pdt-lv-tab-events"
      hidden={@tab != "events"}
    >
      <p :if={@client_dropped > 0} id="pdt-client-dropped" class="pdt-hint pdt-snapshot__more">
        {@client_dropped} client events over the rate limit were not logged.
      </p>
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
      data-pdt-polling={if(@polling?, do: "on", else: "off")}
      data-pdt-reading={to_string(@tree_pending?)}
    >
      <.tree tree={@tree} inspected={@inspected} />
    </div>
    """
  end

  attr :snapshot, :any, required: true
  attr :pending?, :boolean, required: true
  attr :last_changed, :list, required: true
  attr :target, :any, required: true

  defp snapshot(assigns) do
    ~H"""
    <div class="pdt-snapshot-bar">
      <button
        id="pdt-snapshot-refresh"
        type="button"
        class="pdt-button"
        phx-click="lv_snapshot"
        phx-target={@target}
      >
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
            data-pdt-snapshot-changed={key in @last_changed}
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

  attr :tree, :any, required: true
  attr :inspected, :any, required: true

  defp tree(%{tree: {:missing, :no_live_view}} = assigns) do
    ~H"""
    <p id="pdt-tree-missing" class="pdt-empty">No LiveView on this page.</p>
    """
  end

  defp tree(%{tree: %{views: _}} = assigns) do
    ~H"""
    <ul id="pdt-tree" class="pdt-tree">
      <li
        :for={{view, index} <- Enum.with_index(@tree.views)}
        id={"pdt-tree-#{index}"}
        data-pdt-root={view.root}
        aria-current={current(selected_view?(view, @inspected))}
      >
        <code class="pdt-tree__view">{short(view.view)}</code>
        <span :if={view.nested?} class="pdt-tag">nested</span>
        <span :if={view.components == []} class="pdt-hint">no components</span>
        <.tree_nodes
          nodes={view.components}
          prefix={"pdt-tree-#{index}"}
          root={view.root}
          inspected={@inspected}
        />
      </li>
    </ul>
    <p :if={@tree.truncated?} class="pdt-hint pdt-snapshot__more">
      Only the first 500 components are shown.
    </p>
    """
  end

  defp tree(assigns) do
    ~H"""
    <p class="pdt-empty">Reading the component tree…</p>
    """
  end

  attr :nodes, :list, required: true
  attr :prefix, :string, required: true
  attr :root, :string, default: nil
  attr :inspected, :any, required: true

  defp tree_nodes(assigns) do
    ~H"""
    <ul :if={@nodes != []}>
      <li
        :for={node <- @nodes}
        id={"#{@prefix}-#{node.cid}"}
        data-pdt-root={@root}
        data-pdt-cid={node.cid}
        aria-current={current(selected_node?(@root, node, @inspected))}
      >
        <code>{short(node.module)}</code>
        <span class="pdt-hint">id {node.id} · cid {node.cid}</span>
        <.tree_nodes nodes={node.children} prefix={@prefix} root={@root} inspected={@inspected} />
      </li>
    </ul>
    """
  end

  defp selected_node?(root, %{cid: cid}, %Inspected{root: root, cid: cid}) when is_binary(root),
    do: true

  defp selected_node?(_root, _node, _inspected), do: false

  attr :inspected, Inspected, required: true
  attr :editor, :any, default: nil

  # The picked element: tag, binding, the function components around it and
  # their caller, with editor links (ADR 16). Without HEEx annotations there are
  # no frames: the strip says how to turn them on.
  defp inspected_strip(assigns) do
    ~H"""
    <section id="pdt-inspected" class="pdt-inspected" aria-label="Inspected element">
      <p class="pdt-inspected__head">
        <strong>Inspected element</strong>
        <code id="pdt-inspected-tag">&lt;{@inspected.tag}&gt;</code>
        <span :if={@inspected.tag_line} id="pdt-inspected-line" class="pdt-hint">
          line {@inspected.tag_line}
        </span>
        <span :if={@inspected.cid} class="pdt-hint">cid {@inspected.cid}</span>
      </p>
      <p :if={@inspected.binding} id="pdt-inspected-binding">
        <code>{@inspected.binding.event}="{@inspected.binding.name}"</code>
        <span :if={@inspected.binding.target} class="pdt-hint">
          target {@inspected.binding.target}
        </span>
      </p>
      <ol :if={@inspected.frames != []} id="pdt-inspected-frames" class="pdt-inspected__frames">
        <li
          :for={{frame, index} <- Enum.with_index(@inspected.frames)}
          id={"pdt-inspected-frame-#{index}"}
        >
          <code>{frame.name}</code>
          <.source file={frame.file} line={frame.line} editor={@editor} />
        </li>
      </ol>
      <p :if={@inspected.caller} id="pdt-inspected-caller">
        <span class="pdt-hint">called from</span>
        <.source file={@inspected.caller.file} line={@inspected.caller.line} editor={@editor} />
      </p>
      <p :if={@inspected.frames == []} id="pdt-inspected-hint" class="pdt-hint">
        No HEEx source annotations found. Set <code>debug_heex_annotations: true</code>
        and <code>debug_attributes: true</code>
        for <code>:phoenix_live_view</code>
        in dev.
      </p>
    </section>
    """
  end

  attr :file, :string, default: nil
  attr :line, :integer, default: nil
  attr :editor, :any, default: nil

  defp source(assigns) do
    assigns =
      assign(
        assigns,
        :href,
        Inspected.editor_url(%{file: assigns.file, line: assigns.line}, assigns.editor)
      )

    ~H"""
    <a :if={@href} href={@href} class="pdt-link" rel="noopener"><code>{@file}:{@line}</code></a>
    <code :if={@file && is_nil(@href)} class="pdt-hint">{@file}:{@line}</code>
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
        <tr
          :for={{row, index} <- Enum.with_index(@rows)}
          id={"pdt-profile-#{index}"}
          data-pdt-row="profile"
          data-pdt-callback={label(row.key)}
          data-pdt-count={row.count}
          data-pdt-total-us={row.total_us}
          data-pdt-max-us={row.max_us}
        >
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
    <li
      id={@id}
      class={["pdt-row", @event.data.error && "pdt-row--error"]}
      {row_attrs("callback", @event,
        "data-pdt-callback": Atom.to_string(@event.data.callback),
        "data-pdt-event": @event.data[:event],
        "data-pdt-error": @event.data.error != nil
      )}
    >
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
      <.stack_args :if={@event.data.error} data={@event.data} />
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

  defp event_row(%{event: %Event{kind: :client}} = assigns) do
    ~H"""
    <li id={@id} class="pdt-row" {row_attrs("client", @event, "data-pdt-event": @event.data.type)}>
      <div class="pdt-row__head">
        <code>{@event.data.type}</code>
      </div>
      <div class="pdt-row__meta">
        <span class="pdt-tag pdt-tag--client" data-pdt-phase="client" title="Fired in the browser">
          client
        </span>
        <span :for={{field, value} <- @event.data.fields} class="pdt-tag" data-pdt-field={field}>
          {field} {to_string(value)}
        </span>
      </div>
    </li>
    """
  end

  defp event_row(%{event: %Event{kind: :render}} = assigns) do
    ~H"""
    <li
      id={@id}
      class={["pdt-row", @event.data.error && "pdt-row--error"]}
      {row_attrs("render", @event, "data-pdt-error": @event.data.error != nil)}
    >
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
      <.stack_args :if={@event.data.error} data={@event.data} />
    </li>
    """
  end

  attr :event, Event, required: true
  attr :root, :string, required: true

  defp phase_tag(%{event: %Event{sid: sid}, root: sid} = assigns) do
    ~H"""
    <span
      class="pdt-tag pdt-tag--http"
      data-pdt-phase="http"
      title="Ran during the HTTP request (dead render)"
    >
      HTTP
    </span>
    """
  end

  defp phase_tag(assigns) do
    ~H"""
    <span class="pdt-tag pdt-tag--live" data-pdt-phase="live" title="Ran in the connected LiveView">
      live
    </span>
    """
  end

  attr :changes, :map, default: nil

  defp changed(%{changes: %{keys: _}} = assigns) do
    ~H"""
    <span
      :for={key <- @changes.keys}
      class="pdt-tag pdt-changed"
      data-pdt-changed={key_name(key)}
      title="Assign changed"
    >
      {key_name(key)}
    </span>
    <span
      :if={@changes.omitted > 0}
      class="pdt-tag pdt-changed"
      data-pdt-changed-more={@changes.omitted}
    >
      +{@changes.omitted} more
    </span>
    """
  end

  defp changed(assigns), do: ~H""

  attr :pushed, :any, default: nil

  defp pushed(%{pushed: :unavailable} = assigns) do
    ~H"""
    <span
      class="pdt-tag pdt-pushed"
      data-pdt-pushed-unavailable
      title="This LiveView version stores pushed events differently: see the server log"
    >
      push_event names unavailable
    </span>
    """
  end

  defp pushed(%{pushed: [_ | _]} = assigns) do
    ~H"""
    <span :for={name <- @pushed} class="pdt-tag pdt-pushed" data-pdt-pushed={name} title="push_event">
      ⇢ {name}
    </span>
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
