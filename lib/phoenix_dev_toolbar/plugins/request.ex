defmodule PhoenixDevToolbar.Plugins.Request do
  @moduledoc false
  # Built-in Request panel collector (ADR 02): one event per routed request,
  # from `[:phoenix, :router_dispatch, :stop | :exception]`. Overall request
  # time, including plugs before the router, is recorded by
  # `PhoenixDevToolbar.Plug`.

  @behaviour PhoenixDevToolbar.Plugin

  alias PhoenixDevToolbar.Context
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Truncate

  @stop [:phoenix, :router_dispatch, :stop]
  @exception [:phoenix, :router_dispatch, :exception]

  @impl true
  def id, do: :request

  @impl true
  def telemetry_events, do: [@stop, @exception]

  @impl true
  def collect_metrics(@stop, {measurements, metadata}, %Context{}) do
    {:record,
     Event.new(:request, :dispatch, route_data(metadata), duration: measurements[:duration])}
  end

  def collect_metrics(@exception, {measurements, metadata}, %Context{}) do
    data =
      metadata
      |> route_data()
      |> Map.put(:error, banner(metadata.kind, metadata.reason))
      |> Map.put(
        :stacktrace,
        Truncate.stacktrace(metadata[:stacktrace], [Phoenix.Router, Plug])
      )

    {:record, Event.new(:request, :exception, data, duration: measurements[:duration])}
  end

  defp route_data(metadata) do
    conn = metadata.conn

    %{
      method: conn.method,
      path: conn.request_path,
      route: metadata[:route],
      handler: handler(metadata),
      status: conn.status,
      path_params: metadata |> Map.get(:path_params, %{}) |> Truncate.redact()
    }
  end

  # Everything below runs in the host's request process: bounded inspects only.

  # `Exception.format_banner/2` inspects throw and exit reasons without limits.
  defp banner(:error, reason), do: :error |> Exception.format_banner(reason) |> Truncate.string()

  defp banner(kind, reason),
    do: Truncate.string("** (#{kind}) " <> Truncate.inspect_value(reason))

  # LiveView routes dispatch to Phoenix.LiveView.Plug: show the view instead.
  defp handler(%{phoenix_live_view: {view, action, _opts, _live_session}}),
    do: Truncate.inspect_value(view) <> " " <> Truncate.inspect_value(action)

  defp handler(%{plug: plug, plug_opts: opts}),
    do: Truncate.inspect_value(plug) <> " " <> Truncate.inspect_value(opts)

  defp handler(_metadata), do: nil
end
