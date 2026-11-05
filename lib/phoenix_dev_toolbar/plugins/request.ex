defmodule PhoenixDevToolbar.Plugins.Request do
  @moduledoc false
  # Built-in Request panel collector (ADR 02): one event per routed request,
  # from `[:phoenix, :router_dispatch, :stop | :exception]`. Overall request
  # time, including plugs before the router, is recorded by
  # `PhoenixDevToolbar.Plug`.

  use PhoenixDevToolbar.Plugin, id: :request, name: "Request"

  alias PhoenixDevToolbar.Components
  alias PhoenixDevToolbar.Context
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Panels
  alias PhoenixDevToolbar.Truncate

  @stop [:phoenix, :router_dispatch, :stop]
  @exception [:phoenix, :router_dispatch, :exception]

  @impl true
  def telemetry_events(_config), do: [@stop, @exception]

  @impl true
  def panel, do: Panels.Request

  # The last response (recorded by PhoenixDevToolbar.Plug) and the exceptions.
  @impl true
  def summary_init(_config), do: %{response: nil, errors: 0}

  @impl true
  def summary_add(summary, %Event{kind: :response, duration: duration, data: data}),
    do: %{summary | response: %{status: data[:status], duration: duration}}

  def summary_add(summary, %Event{kind: :exception}), do: %{summary | errors: summary.errors + 1}
  def summary_add(summary, %Event{}), do: summary

  @impl true
  def badges(%{response: response, errors: errors}) do
    response_badge(response) ++ errors_badge(errors)
  end

  defp response_badge(nil), do: []

  defp response_badge(%{status: status, duration: duration}),
    do: [
      %{
        id: "response",
        text: "#{status} · #{Components.duration(duration)}",
        level: level(status)
      }
    ]

  defp errors_badge(0), do: []

  defp errors_badge(errors),
    do: [%{id: "errors", text: "#{errors} #{plural(errors, "error", "errors")}", level: :error}]

  defp level(status) when is_integer(status) and status >= 500, do: :error
  defp level(status) when is_integer(status) and status >= 400, do: :warn
  defp level(_status), do: :ok

  defp plural(1, one, _many), do: one
  defp plural(_n, _one, many), do: many

  @impl true
  def collect(@stop, {measurements, metadata}, %Context{}) do
    {:record,
     Event.new(:request, :dispatch, route_data(metadata), duration: measurements[:duration])}
  end

  def collect(@exception, {measurements, metadata}, %Context{}) do
    data =
      metadata
      |> route_data()
      |> Map.put(:error, Truncate.banner(metadata.kind, metadata.reason))
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

  # LiveView routes dispatch to Phoenix.LiveView.Plug: show the view instead.
  defp handler(%{phoenix_live_view: {view, action, _opts, _live_session}}),
    do: Truncate.inspect_value(view) <> " " <> Truncate.inspect_value(action)

  defp handler(%{plug: plug, plug_opts: opts}),
    do: Truncate.inspect_value(plug) <> " " <> Truncate.inspect_value(opts)

  defp handler(_metadata), do: nil
end
