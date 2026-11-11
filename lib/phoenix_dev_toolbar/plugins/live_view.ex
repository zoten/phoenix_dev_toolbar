defmodule PhoenixDevToolbar.Plugins.LiveView do
  @moduledoc """
  The LiveView tab ([ADR 07](https://github.com/zoten/phoenix_dev_toolbar/blob/main/adr/07-live-view-panel.md)): a profiler of every
  callback and render of the page's LiveViews and LiveComponents, the assigns and
  how they change, an event log (server and browser) and the component tree. Part
  of `:defaults`. It takes no options.

      config :phoenix_dev_toolbar, plugins: [:defaults]

  Leave it out with `{:exclude, PhoenixDevToolbar.Plugins.LiveView}`. Assigns are
  bounded and redacted (see the `redact:` option of the application config).
  """

  # Built-in LiveView collector (ADR 02): one `:callback` event per LiveView and
  # LiveComponent callback, one `:render` event per render.
  #
  # Runs inside the host's LiveView (or dead render request) process, and only
  # for tracked processes: the collector returns before reaching the plugin for
  # everything else. So every value is bounded (Truncate) and nothing calls
  # another process.
  #
  # LiveView emits a component `render` span only when it renders one component
  # on its own: after a component `handle_event` or a `send_update`
  # (`Diff.write_component`, LiveView 1.2+; 1.1 has none). Components rendered
  # as part of their LiveView's render are timed within that render only.

  use PhoenixDevToolbar.Plugin, id: :live_view, name: "LiveView"

  alias Phoenix.LiveView.Socket
  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Components
  alias PhoenixDevToolbar.Context
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.LiveViewCompat
  alias PhoenixDevToolbar.Truncate

  @lv [:phoenix, :live_view]
  @lc [:phoenix, :live_component]
  @name_bytes 128
  @params_bytes 2048
  @id_inspect [limit: 5, printable_limit: 128]

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config) do
    view =
      for callback <- [:mount, :handle_params, :handle_event],
          stage <- [:stop, :exception],
          do: @lv ++ [callback, stage]

    component =
      for callback <- [:handle_event, :update],
          stage <- [:stop, :exception],
          do: @lc ++ [callback, stage]

    view ++ component ++ [@lv ++ [:render, :stop], @lv ++ [:render, :exception]]
  end

  @impl PhoenixDevToolbar.Plugin
  def panel, do: PhoenixDevToolbar.Panels.LiveView

  @impl PhoenixDevToolbar.Plugin
  def summary_init(_config), do: %{callbacks: 0, slowest_us: 0}

  @impl PhoenixDevToolbar.Plugin
  def summary_add(summary, %Event{kind: :callback, duration: duration}),
    do: %{callbacks: summary.callbacks + 1, slowest_us: max(summary.slowest_us, duration || 0)}

  def summary_add(summary, %Event{}), do: summary

  @impl PhoenixDevToolbar.Plugin
  def badges(%{callbacks: 0}), do: []

  def badges(%{callbacks: callbacks, slowest_us: slowest_us}) do
    [
      %{
        id: "live",
        text: "#{callbacks} #{noun(callbacks)} · max #{Components.duration(slowest_us)}",
        level: :info,
        title: "LiveView callbacks and the slowest one"
      }
    ]
  end

  defp noun(1), do: "callback"
  defp noun(_callbacks), do: "callbacks"

  @impl PhoenixDevToolbar.Plugin
  # LiveView callbacks run in the LiveView process itself, tracked through the
  # pdict: a `$callers` child is never the page's LiveView.
  def collect(_event, _payload, %Context{source: :caller}), do: :skip

  def collect(@lv ++ [:render, stage], {measurements, metadata}, _context),
    do: render(stage, measurements, metadata)

  def collect(@lv ++ [callback, stage], {measurements, metadata}, _context),
    do: callback(callback, stage, nil, measurements, metadata)

  def collect(@lc ++ [callback, stage], {measurements, metadata}, _context),
    do: callback(callback, stage, metadata.component, measurements, metadata)

  ## Callbacks

  defp callback(callback, stage, component, measurements, %{socket: %Socket{} = socket} = meta) do
    data =
      %{
        callback: callback,
        view: socket.view,
        component: component,
        cid: nil,
        id: nil,
        count: nil,
        connected?: Phoenix.LiveView.connected?(socket),
        nested?: LiveViewCompat.nested?(socket),
        event: name(meta[:event]),
        params: params(callback, meta),
        changes: nil,
        pushed: nil,
        error: nil,
        stacktrace: []
      }
      |> Map.merge(component_data(callback, component, socket, meta))
      |> Map.merge(outcome(stage, callback, socket, meta))

    {:record, Event.new(:live_view, :callback, data, duration: measurements[:duration])}
  end

  defp params(callback, %{params: params}) when callback in [:handle_event, :handle_params],
    do: Truncate.preview(params, @params_bytes)

  defp params(_callback, _metadata), do: nil

  defp component_data(_callback, nil, _socket, _metadata), do: %{}

  # `update` metadata carries the parent socket and every component updated in
  # one batch (`update_many/1`): time the batch, name the first.
  defp component_data(:update, _component, _socket, %{assigns_sockets: assigns_sockets}) do
    first_id =
      case assigns_sockets do
        [{%{id: id}, _socket} | _] -> component_id(id)
        _ -> nil
      end

    %{count: length(assigns_sockets), id: first_id}
  end

  defp component_data(_callback, _component, %Socket{assigns: assigns}, _metadata) do
    cid =
      case assigns do
        %{myself: %Phoenix.LiveComponent.CID{cid: cid}} -> cid
        _ -> nil
      end

    %{cid: cid, id: component_id(assigns[:id])}
  end

  # `update` `:stop` metadata carries the sockets before the update (plus the
  # updated ones for `update_many/1` only): timed, not diffed.
  defp outcome(:stop, :update, _socket, _metadata), do: %{}

  defp outcome(:stop, _callback, socket, _metadata) do
    %{
      changes: Truncate.changes(socket.assigns, LiveViewCompat.changed_keys(socket)),
      pushed: pushed(LiveViewCompat.push_event_names(socket))
    }
  end

  defp outcome(:exception, _callback, _socket, %{kind: kind, reason: reason} = metadata),
    do: %{error: Truncate.banner(kind, reason), stacktrace: crash_stacktrace(metadata)}

  defp pushed({:ok, names}), do: names
  defp pushed(:unavailable), do: :unavailable

  ## Renders

  defp render(:stop, measurements, metadata), do: record_render(measurements, metadata, %{})

  defp render(:exception, measurements, %{kind: kind, reason: reason} = metadata),
    do:
      record_render(measurements, metadata, %{
        error: Truncate.banner(kind, reason),
        stacktrace: crash_stacktrace(metadata)
      })

  # Exception path only (rare): host app frames first (ADR 07).
  defp crash_stacktrace(metadata),
    do: Truncate.exception_stacktrace(metadata[:stacktrace], Collector.host_apps())

  defp record_render(measurements, %{socket: %Socket{} = socket} = metadata, extra) do
    data =
      Map.merge(
        %{
          view: socket.view,
          component: metadata[:component],
          cid: metadata[:cid],
          id: component_id(metadata[:id]),
          force?: metadata[:force?],
          changed?: metadata[:changed?],
          error: nil,
          stacktrace: []
        },
        extra
      )

    {:record, Event.new(:live_view, :render, data, duration: measurements[:duration])}
  end

  defp component_id(nil), do: nil
  defp component_id(id), do: Truncate.inspect_value(id, @id_inspect)

  defp name(nil), do: nil
  defp name(name) when is_binary(name), do: Truncate.string(name, @name_bytes)
  defp name(name), do: Truncate.inspect_value(name, @id_inspect)
end
