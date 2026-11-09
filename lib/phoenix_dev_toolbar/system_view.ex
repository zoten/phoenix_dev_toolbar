defmodule PhoenixDevToolbar.SystemView do
  @moduledoc false
  # The System tab's sections (ADR 11), as function components: a supervisor's
  # children, the message trace, the top processes, the applications, peeked
  # messages and the state read, each with its empty and error states. The tab
  # (PhoenixDevToolbar.Panels.System) keeps the state and the events; `target`
  # is its `@myself`, for the process links.

  use Phoenix.Component

  import PhoenixDevToolbar.Components, only: [bytes: 1]

  alias PhoenixDevToolbar.ProcessTree
  alias PhoenixDevToolbar.ProcessView
  alias PhoenixDevToolbar.Tracer

  attr :children, :any, required: true
  attr :target, :any, required: true

  def children(%{children: :loading} = assigns) do
    ~H"""
    <p class="pdt-hint">Reading…</p>
    """
  end

  def children(%{children: {:ok, counts, :too_many}} = assigns) do
    assigns = assign(assigns, :counts, counts)

    ~H"""
    <p id="pdt-system-children-counts" class="pdt-hint">
      {@counts.specs} children ({@counts.workers} workers, {@counts.supervisors} supervisors, {@counts.active} running): more than {ProcessTree.max_children()}, the list is not read.
    </p>
    """
  end

  def children(%{children: {:ok, counts, list}} = assigns) do
    assigns = assign(assigns, counts: counts, list: list)

    ~H"""
    <p id="pdt-system-children-counts" class="pdt-hint">
      {@counts.specs} children: {@counts.workers} workers, {@counts.supervisors} supervisors, {@counts.active} running.
    </p>
    <ul :if={@list != []} id="pdt-system-children-list" class="pdt-list">
      <li :for={child <- @list} class="pdt-row pdt-process__relation">
        <ProcessView.pid_link
          :if={is_pid(child.pid)}
          id={inspect(child.pid)}
          link="inspect"
          target={@target}
        />
        <code :if={not is_pid(child.pid)}>{child.pid}</code>
        <span>{child.id}</span>
        <span class="pdt-tag">{child.type}</span>
        <span class="pdt-hint">{child.modules}</span>
      </li>
    </ul>
    """
  end

  def children(%{children: {:error, reason}} = assigns) do
    assigns = assign(assigns, :message, children_error(reason))

    ~H"""
    <p id="pdt-system-children-error" class="pdt-hint">{@message}</p>
    """
  end

  defp children_error(:timeout), do: "No answer within 1s: the supervisor is busy."
  defp children_error(:dead), do: "The supervisor exited."
  defp children_error(:not_supervisor), do: "Not a supervisor."

  attr :trace, :any, required: true
  attr :target, :any, required: true

  def trace(%{trace: {:error, why}} = assigns) do
    assigns = assign(assigns, :why, why)

    ~H"""
    <p id="pdt-system-trace-error" class="pdt-hint">{@why}</p>
    """
  end

  def trace(%{trace: %{}} = assigns) do
    ~H"""
    <p id="pdt-system-trace-status" class="pdt-hint" role="status">
      {length(@trace.events)} of at most {Tracer.max_events()} messages, oldest first, redacted · {trace_state(
        @trace
      )}
    </p>
    <ol :if={@trace.events != []} id="pdt-system-trace-list" class="pdt-list">
      <li :for={event <- @trace.events} class="pdt-row pdt-process__relation">
        <span class="pdt-time">+{event.at_ms} ms</span>
        <span :if={event.dir == :in} class="pdt-tag" title="Received">in</span>
        <span :if={event.dir == :out} class="pdt-tag" title="Sent">out</span>
        <ProcessView.pid_link
          :if={is_pid(event.peer)}
          id={inspect(event.peer)}
          link="inspect"
          target={@target}
        />
        <code :if={is_binary(event.peer)}>{event.peer}</code>
        <pre class="pdt-system__message">{event.message}</pre>
      </li>
    </ol>
    """
  end

  def trace(assigns) do
    ~H"""
    <p class="pdt-hint">Starting…</p>
    """
  end

  defp trace_state(%{running?: true, left_ms: left}),
    do: "tracing, stops in #{div(left + 999, 1000)} s"

  defp trace_state(%{stopped: :limit}), do: "stopped at the message limit"
  defp trace_state(%{stopped: :time}), do: "stopped after 10 s"
  defp trace_state(%{stopped: :exited}), do: "stopped: the process exited"
  defp trace_state(%{stopped: :stopped}), do: "stopped"

  attr :top, :any, required: true
  attr :target, :any, required: true

  def top(%{top: {:ok, rows}} = assigns) do
    assigns = assign(assigns, :rows, rows)

    ~H"""
    <table id="pdt-system-top-table" class="pdt-table">
      <thead>
        <tr>
          <th>Process</th>
          <th>Name</th>
          <th>Memory</th>
          <th>Queue</th>
          <th>Reductions / s</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @rows}>
          <td><ProcessView.pid_link id={inspect(row.pid)} link="inspect" target={@target} /></td>
          <td>
            <code>{row.name}</code>
            <span :if={row.toolbar?} class="pdt-tag" title="Part of the dev toolbar itself">
              toolbar
            </span>
          </td>
          <td>{bytes(row.memory)}</td>
          <td>{row.queue}</td>
          <td>{row.reductions_per_second || "…"}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  def top(%{top: {:error, {:too_many, count}}} = assigns) do
    assigns = assign(assigns, :count, count)

    ~H"""
    <p id="pdt-system-top-error" class="pdt-hint">
      {@count} processes: too many to sweep from the panel.
    </p>
    """
  end

  def top(assigns) do
    ~H"""
    <p :if={is_nil(@top)} class="pdt-hint">
      Read every process once and list the 50 that hold the most.
    </p>
    """
  end

  attr :apps, :any, required: true
  attr :target, :any, required: true

  def apps(%{apps: {:ok, apps}} = assigns) do
    assigns = assign(assigns, :groups, Enum.group_by(apps, & &1.group))

    ~H"""
    <.app_group
      :if={@groups[:host]}
      id="pdt-system-apps-host"
      title="Your app and its deps"
      apps={@groups[:host]}
      target={@target}
      open
    />
    <.app_group
      :if={@groups[:elixir]}
      id="pdt-system-apps-elixir"
      title="Elixir"
      apps={@groups[:elixir]}
      target={@target}
    />
    <.app_group
      :if={@groups[:otp]}
      id="pdt-system-apps-otp"
      title="OTP"
      apps={@groups[:otp]}
      target={@target}
    />
    """
  end

  def apps(%{apps: {:error, _reason}} = assigns) do
    ~H"""
    <p id="pdt-system-apps-error" class="pdt-hint">
      The application controller did not answer in time.
    </p>
    """
  end

  def apps(assigns) do
    ~H"""
    <p class="pdt-hint">Reading…</p>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :apps, :list, required: true
  attr :target, :any, required: true
  attr :open, :boolean, default: false

  defp app_group(assigns) do
    ~H"""
    <details id={@id} class="pdt-system__apps" open={@open}>
      <summary>{@title} ({length(@apps)})</summary>
      <ul class="pdt-list">
        <li
          :for={app <- @apps}
          id={"pdt-system-app-#{app.name}"}
          class="pdt-row pdt-process__relation"
        >
          <strong>{app.name}</strong>
          <span class="pdt-hint">{app.version}</span>
          <ProcessView.pid_link
            :if={app.supervisor}
            id={inspect(app.supervisor)}
            link="inspect"
            target={@target}
          />
          <span class="pdt-hint pdt-system__desc">{app.description}</span>
        </li>
      </ul>
    </details>
    """
  end

  attr :peek, :any, required: true

  def peek(%{peek: {:ok, [], _total}} = assigns),
    do: ~H"""
    <p id="pdt-system-messages-empty" class="pdt-hint">The queue is empty.</p>
    """

  def peek(%{peek: {:ok, _shown, _total}} = assigns) do
    ~H"""
    <p class="pdt-hint">
      The first {length(elem(@peek, 1))} of {elem(@peek, 2)}, oldest first, redacted:
    </p>
    <ol id="pdt-system-messages-list" class="pdt-list">
      <li :for={message <- elem(@peek, 1)}><pre>{message}</pre></li>
    </ol>
    """
  end

  def peek(%{peek: {:error, why}} = assigns) do
    assigns = assign(assigns, :why, why)

    ~H"""
    <p id="pdt-system-messages-error" class="pdt-hint">{@why}</p>
    """
  end

  attr :status, :any, required: true

  def status(%{status: {:ok, _status}} = assigns) do
    ~H"""
    <p class="pdt-hint">{elem(@status, 1).module} · {elem(@status, 1).sys_state}</p>
    <pre id="pdt-system-state-value">{elem(@status, 1).state}</pre>
    """
  end

  def status(%{status: {:error, reason}} = assigns) do
    assigns = assign(assigns, :message, status_error(reason))

    ~H"""
    <p id="pdt-system-state-error" class="pdt-hint" role="status">{@message}</p>
    """
  end

  def status(assigns), do: ~H""

  defp status_error(:timeout), do: "No answer within 1s: the process is busy."
  defp status_error(:dead), do: "The process exited."
  defp status_error(:not_otp), do: "Not an OTP process: it does not answer :sys."

  defp status_error(:busy),
    do:
      "Not waiting in a server loop: busy in a callback (try again), or a Task, which never answers :sys."

  defp status_error(:failed), do: "The process failed to report its state."
  defp status_error(:suspended), do: "Suspended: it answers nothing until resumed."
  defp status_error(:too_soon), do: "One read a second: try again."

  defp status_error(:policy),
    do: "Reading state follows the actions setting: not from this browser."
end
