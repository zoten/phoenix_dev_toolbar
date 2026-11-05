defmodule PhoenixDevToolbar.Plugins.LiveView do
  @moduledoc false
  # Built-in LiveView collector (ADR 02): one `:callback` event per LiveView and
  # LiveComponent callback, one `:render` event per LiveView render.
  #
  # Runs inside the host's LiveView (or dead render request) process, and only
  # for tracked processes: the collector returns before reaching the plugin for
  # everything else. So every value is bounded (Truncate) and nothing calls
  # another process.
  #
  # Component renders run inside their LiveView's render span, often many per
  # render: they are folded in the pdict (at most @fold_size entries) and stored
  # with the LiveView render instead of flooding the session buffer. A component
  # render outside a LiveView render (after `send_update`) is stored on its own.

  @behaviour PhoenixDevToolbar.Plugin

  alias Phoenix.LiveView.Socket
  alias PhoenixDevToolbar.Context
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.LiveViewCompat
  alias PhoenixDevToolbar.Truncate

  @lv [:phoenix, :live_view]
  @lc [:phoenix, :live_component]
  @fold :pdt_render_fold
  @fold_size 10
  @name_bytes 128
  @id_inspect [limit: 5, printable_limit: 128]
  @empty_fold %{entries: %{}, rest_count: 0, rest_native: 0}

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

    render = for stage <- [:start, :stop, :exception], do: @lv ++ [:render, stage]

    view ++ component ++ render
  end

  @doc false
  @spec fold_key() :: atom()
  def fold_key, do: @fold

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
    do: params |> Truncate.redact() |> Truncate.inspect_value()

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

  # `update` `:stop` metadata is its `:start` metadata: nothing to diff.
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

  defp render(:start, _measurements, %{component: _component}), do: :skip

  defp render(:start, _measurements, _metadata) do
    Process.put(@fold, @empty_fold)
    :skip
  end

  defp render(:stop, measurements, %{component: _component} = metadata) do
    case Process.get(@fold) do
      nil ->
        record_render(measurements, metadata, %{
          cid: metadata[:cid],
          id: component_id(metadata[:id])
        })

      fold ->
        Process.put(@fold, fold_add(fold, metadata, measurements[:duration] || 0))
        :skip
    end
  end

  defp render(:stop, measurements, metadata) do
    fold = Process.delete(@fold) || @empty_fold
    record_render(measurements, metadata, fold_data(fold))
  end

  # A component render that raises raises its LiveView render too.
  defp render(:exception, _measurements, %{component: _component}), do: :skip

  defp render(:exception, measurements, %{kind: kind, reason: reason} = metadata) do
    _ = Process.delete(@fold)
    record_render(measurements, metadata, %{error: Truncate.banner(kind, reason)})
  end

  defp record_render(measurements, %{socket: %Socket{} = socket} = metadata, extra) do
    data =
      Map.merge(
        %{
          view: socket.view,
          component: metadata[:component],
          cid: nil,
          id: nil,
          force?: metadata[:force?],
          changed?: metadata[:changed?],
          components: [],
          rest: %{count: 0, us: 0},
          error: nil
        },
        extra
      )

    {:record, Event.new(:live_view, :render, data, duration: measurements[:duration])}
  end

  # Keeps the @fold_size slowest components; the others are summed in `rest`.
  defp fold_add(%{entries: entries} = fold, %{cid: cid} = metadata, duration) do
    case entries do
      %{^cid => {component, id, count, total}} ->
        %{fold | entries: %{entries | cid => {component, id, count + 1, total + duration}}}

      _ when map_size(entries) < @fold_size ->
        %{fold | entries: Map.put(entries, cid, entry(metadata, duration))}

      _ ->
        {fastest, {_c, _id, count, total}} =
          Enum.min_by(entries, fn {_cid, entry} -> elem(entry, 3) end)

        evict(fold, fastest, count, total, metadata, duration)
    end
  end

  defp evict(fold, fastest, count, total, metadata, duration) when duration > total do
    %{
      fold
      | entries:
          fold.entries |> Map.delete(fastest) |> Map.put(metadata.cid, entry(metadata, duration)),
        rest_count: fold.rest_count + count,
        rest_native: fold.rest_native + total
    }
  end

  defp evict(fold, _fastest, _count, _total, _metadata, duration),
    do: %{fold | rest_count: fold.rest_count + 1, rest_native: fold.rest_native + duration}

  defp entry(metadata, duration), do: {metadata.component, metadata[:id], 1, duration}

  defp fold_data(%{entries: entries, rest_count: rest_count, rest_native: rest_native}) do
    components =
      entries
      |> Enum.sort_by(fn {_cid, entry} -> elem(entry, 3) end, :desc)
      |> Enum.map(fn {cid, {component, id, count, total}} ->
        %{
          component: component,
          cid: cid,
          id: component_id(id),
          count: count,
          us: Event.native_to_us(total)
        }
      end)

    %{components: components, rest: %{count: rest_count, us: Event.native_to_us(rest_native)}}
  end

  defp component_id(nil), do: nil
  defp component_id(id), do: Truncate.inspect_value(id, @id_inspect)

  defp name(nil), do: nil
  defp name(name) when is_binary(name), do: Truncate.string(name, @name_bytes)
  defp name(name), do: Truncate.inspect_value(name, @id_inspect)
end
