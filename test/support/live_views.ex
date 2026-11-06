defmodule DemoWeb.PageLive do
  @moduledoc false
  # A host application LiveView, outside the toolbar namespace. "query" emits
  # the telemetry event an Ecto query on DemoWeb.FakeRepo would.
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_event("query", %{"sql" => sql}, socket) do
    query(sql)
    {:noreply, socket}
  end

  # `count` queries in this callback, or in a Task.async child of it.
  def handle_event("queries", %{"sql" => sql, "count" => count} = params, socket) do
    run = fn -> for _n <- 1..count, do: query(sql) end

    case params["task"] do
      true -> run |> Task.async() |> Task.await()
      _inline -> run.()
    end

    {:noreply, socket}
  end

  # The span Oban.Engine.insert_job/3 emits in the inserting process
  # (deps/oban/lib/oban/engine.ex, with_span/4), for the Oban example plugin.
  def handle_event("enqueue", %{"worker" => worker, "queue" => queue}, socket) do
    job =
      %{"user_id" => 1, "token" => "s3cret"}
      |> Oban.Job.new(worker: worker, queue: queue)
      |> Ecto.Changeset.apply_changes()

    :telemetry.span([:oban, :engine, :insert_job], %{conf: nil, engine: Oban.Engines.Lite}, fn ->
      {{:ok, job}, %{conf: nil, engine: Oban.Engines.Lite, job: job}}
    end)

    {:noreply, socket}
  end

  # What a third party plugin would listen to (TestPlugins.Tabbed).
  def handle_event("echo", %{"value" => value}, socket) do
    :telemetry.execute([:pdt_test, :echo], %{}, %{value: value})
    {:noreply, socket}
  end

  @impl true
  def render(assigns), do: ~H"<p>page</p>"

  defp query(sql) do
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
  end
end
