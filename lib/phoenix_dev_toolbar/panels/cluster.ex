defmodule PhoenixDevToolbar.Panels.Cluster do
  @moduledoc false
  # The Cluster tab (ADR 12): ClusterInfo read in a task while the tab is shown
  # and the panel visible, every `refresh_ms`. One read in flight at a time.

  use PhoenixDevToolbar.Panel

  import PhoenixDevToolbar.Components, only: [bytes: 1]

  alias PhoenixDevToolbar.ClusterInfo
  alias PhoenixDevToolbar.Panel
  alias PhoenixDevToolbar.Panels.Cluster, as: ClusterPanel
  alias PhoenixDevToolbar.Plugins

  @node_timeout_ms 1000

  @impl Phoenix.LiveComponent
  def mount(socket),
    do: {:ok, assign(socket, cluster: nil, reading?: false, timer: nil, prev: nil)}

  @impl Panel
  def handle_reset(_events, socket), do: read(socket)

  @impl Panel
  def handle_events(_events, socket), do: socket

  @impl Panel
  def handle_props(%{assigns: assigns} = socket) do
    prev = assigns.prev || %{shown?: false, visible?: false}
    socket = assign(socket, :prev, Map.take(assigns, [:shown?, :visible?]))

    case not (prev.shown? and prev.visible?) do
      true -> read(socket)
      false -> socket
    end
  end

  @impl Panel
  def handle_info({:refresh, timer}, %{assigns: %{timer: timer}} = socket),
    do: read(assign(socket, :timer, nil))

  def handle_info(_message, socket), do: socket

  @impl Phoenix.LiveComponent
  def handle_event("refresh", _params, socket), do: {:noreply, read(socket)}
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveComponent
  def handle_async(:cluster, {:ok, cluster}, socket),
    do: {:noreply, socket |> assign(cluster: cluster, reading?: false) |> schedule()}

  def handle_async(:cluster, _exit, socket),
    do: {:noreply, socket |> assign(:reading?, false) |> schedule()}

  defp polling?(%{assigns: %{shown?: true, visible?: true}}), do: true
  defp polling?(_socket), do: false

  defp read(%{assigns: %{reading?: true}} = socket), do: socket

  defp read(socket) do
    case polling?(socket) do
      true ->
        socket
        |> assign(:reading?, true)
        |> start_async(:cluster, fn -> ClusterInfo.read(@node_timeout_ms) end)

      false ->
        socket
    end
  end

  # The next read, only while someone looks.
  defp schedule(socket) do
    case polling?(socket) and is_nil(socket.assigns.timer) do
      true ->
        token = make_ref()
        every = Plugins.Cluster.config(socket.assigns[:config]).refresh_ms
        _ = Panel.send_after(ClusterPanel, socket.assigns.id, {:refresh, token}, every)
        assign(socket, :timer, token)

      false ->
        socket
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="pdt-cluster" class="pdt-process">
      <p :if={is_nil(@cluster)} class="pdt-empty">Reading the nodes…</p>
      <div :if={@cluster} class="pdt-snapshot-bar">
        <strong id="pdt-cluster-node">{@cluster.node}</strong>
        <span :if={not @cluster.alive?} id="pdt-cluster-local" class="pdt-hint">
          This node is not distributed: start it with --sname or --name to connect others.
        </span>
        <span :if={@cluster.alive?} class="pdt-hint">
          {length(@cluster.nodes) - 1} connected<span :if={@cluster.more > 0}> (and {@cluster.more} more not shown)</span>
        </span>
        <button
          id="pdt-cluster-refresh"
          type="button"
          class="pdt-button pdt-button--small"
          phx-click="refresh"
          phx-target={@myself}
          aria-busy={to_string(@reading?)}
        >
          Refresh
        </button>
      </div>
      <table :if={@cluster} id="pdt-cluster-nodes" class="pdt-table">
        <thead>
          <tr>
            <th>Node</th>
            <th>Kind</th>
            <th>Round trip</th>
            <th>Processes</th>
            <th>Memory</th>
            <th>OTP</th>
            <th>Uptime</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={node <- @cluster.nodes} id={"pdt-cluster-node-#{node_id(node.name)}"}>
            <td><code>{node.name}</code></td>
            <td><span class="pdt-tag">{kind(node.kind)}</span></td>
            <%= case node.stats do %>
              <% %{} = stats -> %>
                <td>{rtt(node.kind, stats.rtt_us)}</td>
                <td>{stats.processes}</td>
                <td>{bytes(stats.memory)}</td>
                <td>{stats.otp}</td>
                <td>{uptime(stats.uptime_s)}</td>
              <% failed -> %>
                <td colspan="5" class="pdt-hint">{failure(failed)}</td>
            <% end %>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp node_id(name), do: :erlang.phash2(name)

  defp kind(:self), do: "this node"
  defp kind(:visible), do: "connected"
  defp kind(:hidden), do: "hidden"

  defp rtt(:self, _us), do: "local"
  defp rtt(_kind, us) when us < 1000, do: "#{us} µs"
  defp rtt(_kind, us), do: "#{Float.round(us / 1000, 1)} ms"

  defp uptime(s) when s < 60, do: "#{s} s"
  defp uptime(s) when s < 3600, do: "#{div(s, 60)} min"
  defp uptime(s), do: "#{div(s, 3600)} h #{div(rem(s, 3600), 60)} min"

  defp failure(:timeout), do: "No answer within 1 s."
  defp failure(:error), do: "The node could not be read."
end
