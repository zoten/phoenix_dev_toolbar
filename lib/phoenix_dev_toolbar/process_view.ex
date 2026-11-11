defmodule PhoenixDevToolbar.ProcessView do
  @moduledoc false
  # How the toolbar shows a process (ADR 09, ADR 10): vital signs with their
  # sparklines, details, links and monitors. Function components shared by the
  # Process tab and the System tab; DOM ids start with `prefix`.

  use Phoenix.Component

  import PhoenixDevToolbar.Components, only: [sparkline: 1, bytes: 1]

  alias PhoenixDevToolbar.ProcessControls

  attr :prefix, :string, required: true
  attr :sample, :map, required: true, doc: "a ProcessInfo.sample/1 with its reductions_per_second"
  attr :series, :map, required: true, doc: "newest first: memory, queue and reductions points"

  def vitals(assigns) do
    ~H"""
    <div
      id={"#{@prefix}-vitals"}
      class="pdt-process__vitals"
      data-samples={length(@series.memory)}
    >
      <.vital
        id={"#{@prefix}-memory"}
        label="Memory"
        value={bytes(@sample.memory)}
        values={Enum.reverse(@series.memory)}
        peak={peak(@series.memory, &bytes/1)}
      />
      <.vital
        id={"#{@prefix}-queue"}
        label="Message queue"
        value={count(@sample.message_queue_len)}
        values={Enum.reverse(@series.queue)}
        peak={peak(@series.queue, &count/1)}
        warn?={@sample.message_queue_len > 100}
      />
      <.vital
        id={"#{@prefix}-reductions"}
        label="Reductions / s"
        title="Work done per second: a reduction is roughly one function call"
        value={
          if(@sample.reductions_per_second,
            do: count(@sample.reductions_per_second),
            else: "…"
          )
        }
        values={Enum.reverse(@series.reductions)}
        peak={peak(@series.reductions, &count/1)}
      />
    </div>
    <dl id={"#{@prefix}-details"} class="pdt-process__details">
      <dt>status</dt>
      <dd>
        {@sample.status}
        <span :if={@sample.status == :waiting and @sample.message_queue_len > 100} class="pdt-hint">
          · between two messages: the queue grows faster than they are handled
        </span>
      </dd>
      <dt>current function</dt>
      <dd><code>{@sample.current_function}</code></dd>
      <dt>heap</dt>
      <dd>
        {words(@sample.heap_size)} heap · {words(@sample.total_heap_size)} total · {words(
          @sample.stack_size
        )} stack
      </dd>
      <dt>GC</dt>
      <dd>
        {@sample.minor_gcs} minor collections since the last full sweep · a full sweep every {@sample.fullsweep_after} minor ones
      </dd>
    </dl>
    """
  end

  attr :prefix, :string, required: true
  attr :relations, :map, required: true, doc: "a ProcessInfo.relations/1"
  attr :link, :string, default: nil, doc: "the event a local process's id sends, with its pid"
  attr :target, :any, default: nil, doc: "the event's phx-target"

  def relations(assigns) do
    ~H"""
    <section id={"#{@prefix}-relations"} class="pdt-process__relations">
      <.relation_list
        id={"#{@prefix}-links"}
        title="Links"
        relations={@relations.links}
        more={@relations.more.links}
        link={@link}
        target={@target}
      />
      <.relation_list
        id={"#{@prefix}-monitors"}
        title="Monitors"
        relations={@relations.monitors}
        more={@relations.more.monitors}
        link={@link}
        target={@target}
      />
      <.relation_list
        id={"#{@prefix}-monitored-by"}
        title="Monitored by"
        relations={@relations.monitored_by}
        more={@relations.more.monitored_by}
        link={@link}
        target={@target}
      />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :values, :list, required: true
  attr :warn?, :boolean, default: false
  attr :peak, :string, default: nil, doc: "the window's highest value, formatted"
  attr :title, :string, default: nil

  defp vital(assigns) do
    ~H"""
    <div id={@id} class={["pdt-vital", @warn? && "pdt-vital--warn"]}>
      <span class="pdt-vital__label" title={@title}>{@label}</span>
      <span class="pdt-vital__value">{@value}</span>
      <.sparkline values={@values} label={sparkline_label(@label, @peak, length(@values))} />
      <span :if={@peak} class="pdt-vital__peak">peak {@peak} over {samples(length(@values))}</span>
    </div>
    """
  end

  # The line is scaled to its own window: the peak gives it a size.
  defp peak([], _format), do: nil
  defp peak(values, format), do: format.(Enum.max(values))

  defp sparkline_label(label, nil, _count), do: label <> " over time"

  defp sparkline_label(label, peak, count),
    do: "#{label} over the last #{samples(count)}, peak #{peak}"

  defp samples(1), do: "1 sample"
  defp samples(count), do: "#{count} samples"

  # 1234567 -> "1,234,567": reductions per second reach the millions.
  defp count(value) when is_integer(value),
    do: value |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+$)/, ",")

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :relations, :list, required: true
  attr :more, :integer, required: true
  attr :link, :string, default: nil
  attr :target, :any, default: nil

  defp relation_list(assigns) do
    ~H"""
    <div id={@id}>
      <h3 class="pdt-process__title">{@title} ({length(@relations) + @more})</h3>
      <p :if={@relations == []} class="pdt-hint">None.</p>
      <ul :if={@relations != []} class="pdt-list">
        <li :for={relation <- @relations} class="pdt-row pdt-process__relation">
          <.pid_link id={relation.id} link={relation.link? && @link} target={@target} />
          <span>{relation.name}</span>
          <span :if={relation.kind == :port} class="pdt-tag">port</span>
          <span :if={relation.toolbar?} class="pdt-tag" title="Part of the dev toolbar itself">
            toolbar
          </span>
          <span
            :if={relation.child?}
            class="pdt-tag pdt-tag--live"
            title="Started by this LiveView ($callers)"
          >
            child
          </span>
        </li>
      </ul>
      <p :if={@more > 0} class="pdt-hint">and {@more} more</p>
    </div>
    """
  end

  attr :prefix, :string, required: true
  attr :target, :any, required: true, doc: "the events' phx-target"
  attr :gate, :any, required: true, doc: "ProcessControls' gate: :ok, {:error, why}, :off or nil"
  attr :confirm, :any, default: nil, doc: "the action waiting for a confirm click"
  attr :note, :any, default: nil, doc: "{:ok | :error, text}: what the last action did"
  attr :suspended?, :boolean, default: false
  attr :suspend?, :boolean, default: true, doc: "offer Suspend and Resume"
  attr :kill_reason, :string, default: "kill", doc: "the reason selected"

  @doc """
  Kill (with a reason) and Suspend for a process, each behind a confirm click,
  or why they are off (ADR 10). Events: `arm` (`action`, `reason`), `confirm`,
  `cancel`, `resume`, `kill_reason` (the select changed).
  """
  def actions(assigns) do
    ~H"""
    <div id={"#{@prefix}-actions"} class="pdt-actions">
      <%= case @gate do %>
        <% nil -> %>
        <% :off -> %>
          <p id={"#{@prefix}-actions-off"} class="pdt-hint">
            Actions are off: set actions: :local in the toolbar config to kill or suspend from here.
          </p>
        <% {:error, why} -> %>
          <p id={"#{@prefix}-actions-off"} class="pdt-hint">{why}</p>
        <% :ok -> %>
          <%= if @confirm do %>
            <span id={"#{@prefix}-confirm-text"} class="pdt-actions__confirm">
              {confirm_text(@confirm)}
            </span>
            <button
              id={"#{@prefix}-confirm"}
              type="button"
              class="pdt-button pdt-button--small pdt-button--danger"
              phx-mounted={Phoenix.LiveView.JS.focus()}
              phx-click="confirm"
              phx-target={@target}
            >
              Confirm
            </button>
            <button
              id={"#{@prefix}-cancel"}
              type="button"
              class="pdt-button pdt-button--small"
              phx-click="cancel"
              phx-target={@target}
            >
              Cancel
            </button>
          <% else %>
            <form
              id={"#{@prefix}-kill-form"}
              class="pdt-actions__kill"
              phx-change="kill_reason"
              phx-submit="arm"
              phx-target={@target}
            >
              <input type="hidden" name="action" value="kill" />
              <select id={"#{@prefix}-kill-reason"} name="reason" aria-label="Exit reason">
                <option value="kill" selected={@kill_reason == "kill"}>kill (untrappable)</option>
                <option value="shutdown" selected={@kill_reason == "shutdown"}>shutdown</option>
                <option value="crash" selected={@kill_reason == "crash"}>crash (RuntimeError)</option>
              </select>
              <button id={"#{@prefix}-kill"} type="submit" class="pdt-button pdt-button--small">
                Kill
              </button>
            </form>
            <button
              :if={@suspend? and not @suspended?}
              id={"#{@prefix}-suspend"}
              type="button"
              class="pdt-button pdt-button--small"
              phx-click="arm"
              phx-value-action="suspend"
              phx-target={@target}
              title={"Freeze it for #{ProcessControls.suspend_seconds()} seconds: it resumes by itself"}
            >
              Suspend {ProcessControls.suspend_seconds()} s
            </button>
          <% end %>
      <% end %>
      <button
        :if={@suspended?}
        id={"#{@prefix}-resume"}
        type="button"
        class="pdt-button pdt-button--small"
        phx-click="resume"
        phx-target={@target}
      >
        Resume
      </button>
      <span
        :if={@note}
        id={"#{@prefix}-action-note"}
        class={["pdt-hint", elem(@note, 0) == :error && "pdt-actions__error"]}
        role="status"
      >
        {elem(@note, 1)}
      </span>
    </div>
    """
  end

  defp confirm_text({:kill, reason}), do: "Kill it (#{reason})?"
  defp confirm_text(:suspend), do: "Suspend it for #{ProcessControls.suspend_seconds()} s?"

  attr :id, :string, required: true, doc: "the pid as inspected, or another id"
  attr :link, :any, default: nil, doc: "the event to send with phx-value-pid, or nil/false"
  attr :target, :any, default: nil

  @doc "A process id: a button sending `link` with the pid when given, else plain code."
  def pid_link(%{link: link} = assigns) when is_binary(link) do
    ~H"""
    <button
      type="button"
      class="pdt-pid-link"
      phx-click={@link}
      phx-value-pid={@id}
      phx-target={@target}
      title="Inspect this process"
    >
      <code>{@id}</code>
    </button>
    """
  end

  def pid_link(assigns), do: ~H"<code>{@id}</code>"

  defp words(words), do: bytes(words * :erlang.system_info(:wordsize))

  attr :prefix, :string, required: true
  attr :target, :any, required: true
  attr :gc, :any, required: true, doc: "ProcessInspector's gc state"
  attr :gc_note, :string, default: nil

  @doc "GC now and what it did (ADR 09): sends `gc`."
  def gc_control(assigns) do
    ~H"""
    <button
      id={"#{@prefix}-gc"}
      type="button"
      class="pdt-button pdt-button--small"
      phx-click="gc"
      phx-target={@target}
      aria-busy={to_string(@gc == :running)}
      title="Run a garbage collection on this process: what is left is memory it really holds"
    >
      {if(@gc == :running, do: "collecting…", else: "GC now")}
    </button>
    <span id={"#{@prefix}-gc-result"} class="pdt-hint" role="status">
      {gc_result(@gc)}<span :if={@gc_note} id={"#{@prefix}-gc-note"}> · {@gc_note}</span>
    </span>
    """
  end

  @doc "The line a polling tab shows while the panel is hidden."
  def paused(assigns) do
    ~H"""
    <p class="pdt-hint pdt-process__paused">Paused while the panel is hidden.</p>
    """
  end

  @doc "What a GC now did, for the line next to its button."
  @spec gc_result(term()) :: String.t()
  def gc_result({:ok, before, after_gc}) when before > after_gc,
    do: "freed #{bytes(before - after_gc)}: #{bytes(before)} → #{bytes(after_gc)}"

  def gc_result({:ok, _before, after_gc}), do: "nothing to free: #{bytes(after_gc)} held"
  def gc_result(:dead), do: "the process exited"
  def gc_result(:too_soon), do: "one collection a second: try again"
  def gc_result(:suspended), do: "suspended: it would only collect once resumed"
  def gc_result(_none_or_running), do: ""
end
