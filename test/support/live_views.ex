defmodule DemoWeb.PageLive do
  @moduledoc false
  # A host application LiveView, outside the toolbar namespace. "query" emits
  # the telemetry event an Ecto query on DemoWeb.FakeRepo would.
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_event("query", %{"sql" => sql}, socket) do
    :telemetry.execute(
      [:demo, :repo, :query],
      %{total_time: System.convert_time_unit(1, :millisecond, :native)},
      %{
        repo: DemoWeb.FakeRepo,
        query: sql,
        params: [],
        source: "users",
        result: {:ok, %{num_rows: 1}}
      }
    )

    {:noreply, socket}
  end

  # What a third party plugin would listen to (TestPlugins.Tabbed).
  def handle_event("echo", %{"value" => value}, socket) do
    :telemetry.execute([:pdt_test, :echo], %{}, %{value: value})
    {:noreply, socket}
  end

  @impl true
  def render(assigns), do: ~H"<p>page</p>"
end
