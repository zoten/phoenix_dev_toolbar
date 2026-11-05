defmodule PhoenixDevToolbar.Plugins.SummariesTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Plugins
  alias PhoenixDevToolbar.Shell

  defp badges(plugin, events) do
    [{plugin, nil}] |> Shell.new() |> Shell.reset(events) |> Shell.badges()
  end

  defp event(plugin, kind, data, duration \\ nil),
    do: %{Event.new(plugin, kind, data, at: 0) | duration: duration}

  test "Ecto counts queries and total time, flags failures" do
    ok = event(:ecto, :query, %{result: {:ok, 1}}, 1200)
    failed = event(:ecto, :query, %{result: {:error, "boom"}}, 300)

    assert [%{id: "queries", text: "1 query · 1.20 ms", level: :info}] =
             badges(Plugins.Ecto, [ok])

    assert [%{text: "2 queries · 1.50 ms", level: :error}] = badges(Plugins.Ecto, [ok, failed])
  end

  test "Request keeps the last response and counts exceptions" do
    response = event(:request, :response, %{status: 404}, 900)
    exception = event(:request, :exception, %{})

    assert badges(Plugins.Request, []) == []

    assert [
             %{id: "response", text: "404 · 0.90 ms", level: :warn},
             %{id: "errors", text: "1 error", level: :error}
           ] = badges(Plugins.Request, [exception, response])
  end

  test "LiveView counts callbacks, not renders, and keeps the slowest" do
    callback = event(:live_view, :callback, %{callback: :handle_event}, 300)
    slow = event(:live_view, :callback, %{callback: :mount}, 700)
    render = event(:live_view, :render, %{}, 9000)

    assert badges(Plugins.LiveView, [render]) == []

    assert [%{id: "live", text: "2 callbacks · max 0.70 ms"}] =
             badges(Plugins.LiveView, [callback, slow, render])
  end
end
