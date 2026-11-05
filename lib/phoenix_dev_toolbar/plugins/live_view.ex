defmodule PhoenixDevToolbar.Plugins.LiveView do
  @moduledoc false
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

  @behaviour PhoenixDevToolbar.Plugin

  alias Phoenix.LiveView.Socket
  alias PhoenixDevToolbar.Context
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.LiveViewCompat
  alias PhoenixDevToolbar.Truncate

  @lv [:phoenix, :live_view]
  @lc [:phoenix, :live_component]
  @name_bytes 128
  @params_bytes 2048
  @id_inspect [limit: 5, printable_limit: 128]

  @impl true
  def id, do: :live_view

  @impl true
  def telemetry_events do
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

  @impl true
  # LiveView callbacks run in the LiveView process itself, tracked through the
  # pdict: a `$callers` child is never the page's LiveView.
  def collect_metrics(_event, _payload, %Context{source: :caller}), do: :skip

  def collect_metrics(@lv ++ [:render, stage], {measurements, metadata}, _context),
    do: render(stage, measurements, metadata)

  def collect_metrics(@lv ++ [callback, stage], {measurements, metadata}, _context),
    do: callback(callback, stage, nil, measurements, metadata)

  def collect_metrics(@lc ++ [callback, stage], {measurements, metadata}, _context),
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
        error: nil
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

  defp outcome(:exception, _callback, _socket, %{kind: kind, reason: reason}),
    do: %{error: Truncate.banner(kind, reason)}

  defp pushed({:ok, names}), do: names
  defp pushed(:unavailable), do: :unavailable

  ## Renders

  defp render(:stop, measurements, metadata), do: record_render(measurements, metadata, %{})

  defp render(:exception, measurements, %{kind: kind, reason: reason} = metadata),
    do: record_render(measurements, metadata, %{error: Truncate.banner(kind, reason)})

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
          error: nil
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
