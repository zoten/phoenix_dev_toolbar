defmodule PhoenixDevToolbar.ProcessControls do
  @moduledoc false
  # The actions' state in a tab that inspects a process (ADR 10), shared by the
  # Process and System tabs: functions over the panel's LiveComponent socket,
  # next to PhoenixDevToolbar.ProcessInspector (the target and its polling).
  #
  # Assigns: `gate` (whether the target may be killed or suspended from here:
  # `:ok`, `{:error, why}`, or `:off` when `actions: false`; read once per
  # target), `confirm` (the action waiting for a confirm click), `note` (what
  # the last action did), `action_at` (one action a second per tab) and
  # `kill_reason` (the select's value).
  #
  # handle_event/4 takes every control event (`gc`, `arm`, `kill_reason`,
  # `confirm`, `cancel`, `resume`) and leaves the socket as is for any other.

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Phoenix.LiveView.Socket
  alias PhoenixDevToolbar.ClientPolicy
  alias PhoenixDevToolbar.ProcessActions
  alias PhoenixDevToolbar.ProcessInspector

  @kill_reasons ["kill", "shutdown", "crash"]
  # At most one action a second.
  @action_every_ms 1000

  @doc "The assigns of a tab with no action pending."
  @spec init(Socket.t()) :: Socket.t()
  def init(socket),
    do: assign(socket, gate: nil, confirm: nil, note: nil, action_at: nil, kill_reason: "kill")

  @doc "A new target: what was pending or said about the previous one goes."
  @spec reset(Socket.t()) :: Socket.t()
  def reset(socket), do: assign(socket, gate: nil, confirm: nil, note: nil)

  @doc """
  The context ProcessActions needs: the client and the panel's own processes,
  from the `pdt_actions` assign the toolbar gives its built-in tabs.
  """
  @spec context(Socket.t() | map()) :: ProcessActions.context()
  def context(%Socket{assigns: assigns}), do: context(assigns)
  def context(assigns), do: Map.merge(%{panel: self()}, assigns[:pdt_actions] || %{})

  @doc "Whether this panel's client may read process data (state, messages)."
  @spec client?(Socket.t() | map()) :: boolean()
  def client?(socket_or_assigns), do: ProcessActions.client(context(socket_or_assigns)) == :ok

  @doc "Reads, once per target, whether it may be killed or suspended from here."
  @spec read_gate(Socket.t()) :: Socket.t()
  def read_gate(%{assigns: %{selected: pid}} = socket) when is_pid(pid),
    do: assign(socket, :gate, gate(pid, context(socket)))

  def read_gate(socket), do: socket

  defp gate(pid, context) do
    case ClientPolicy.mode() do
      false -> :off
      _on -> ProcessActions.allowed(pid, context)
    end
  end

  @doc "Handles a control event; any other leaves the socket unchanged."
  @spec handle_event(String.t(), map(), Socket.t(), module()) :: Socket.t()
  def handle_event("gc", _params, socket, module), do: ProcessInspector.gc(socket, module)
  def handle_event("arm", params, socket, _module), do: arm(socket, params)
  def handle_event("kill_reason", params, socket, _module), do: pick_reason(socket, params)
  def handle_event("confirm", _params, socket, _module), do: confirm(socket)
  def handle_event("cancel", _params, socket, _module), do: assign(socket, :confirm, nil)
  def handle_event("resume", _params, socket, _module), do: resume(socket)
  def handle_event(_event, _params, socket, _module), do: socket

  # The first click: the action waits for a confirm.
  defp arm(socket, %{"action" => "kill", "reason" => reason}) when reason in @kill_reasons,
    do: assign(socket, confirm: {:kill, reason}, note: nil, kill_reason: reason)

  defp arm(socket, %{"action" => "suspend"}), do: assign(socket, confirm: :suspend, note: nil)
  defp arm(socket, _params), do: socket

  # The select changed: the reason is kept across renders.
  defp pick_reason(socket, %{"reason" => reason}) when reason in @kill_reasons,
    do: assign(socket, :kill_reason, reason)

  defp pick_reason(socket, _params), do: socket

  # The confirm click: runs the armed action, at most one a second.
  defp confirm(%{assigns: %{selected: pid, confirm: action}} = socket)
       when is_pid(pid) and action != nil do
    case action_allowed?(socket) do
      true ->
        socket
        |> assign(confirm: nil, action_at: System.monotonic_time(:millisecond))
        |> assign(:note, run(action, pid, context(socket)))
        |> ProcessInspector.read_sample()

      false ->
        assign(socket, :note, {:error, "One action a second: try again."})
    end
  end

  defp confirm(socket), do: socket

  defp resume(%{assigns: %{selected: pid}} = socket) when is_pid(pid) do
    note =
      case ProcessActions.resume(pid) do
        :ok -> {:ok, "Resumed."}
        {:error, why} -> {:error, why}
      end

    socket |> assign(:note, note) |> ProcessInspector.read_sample()
  end

  defp resume(socket), do: socket

  defp run({:kill, reason}, pid, context) do
    case ProcessActions.kill(pid, reason, context) do
      :ok -> {:ok, "Exit signal sent (#{reason})."}
      error -> error
    end
  end

  defp run(:suspend, pid, context) do
    case ProcessActions.suspend(pid, context) do
      :ok -> {:ok, "Suspended for #{suspend_seconds()} s: it resumes by itself."}
      error -> error
    end
  end

  @doc "How long Suspend lasts, in seconds, for labels."
  @spec suspend_seconds() :: pos_integer()
  def suspend_seconds, do: div(ProcessActions.suspend_ms(), 1000)

  defp action_allowed?(%{assigns: %{action_at: nil}}), do: true

  defp action_allowed?(%{assigns: %{action_at: at}}),
    do: System.monotonic_time(:millisecond) - at >= @action_every_ms
end
