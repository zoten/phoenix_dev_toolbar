defmodule DemoWeb.PageLive do
  @moduledoc false
  # A host application LiveView, outside the toolbar namespace. "query" emits
  # the telemetry event an Ecto query on DemoWeb.FakeRepo would.
  use Phoenix.LiveView

  require Ecto.Query

  @impl Phoenix.LiveView
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl Phoenix.LiveView
  def handle_event("query", %{"sql" => sql}, socket) do
    query(sql)
    {:noreply, socket}
  end

  # `count` queries in this callback, or in a Task.async child of it; with
  # "origin", from a call site (the stacktrace of a repo with `stacktrace: true`).
  def handle_event("queries", %{"sql" => sql, "count" => count} = params, socket) do
    stacktrace = origin(params["origin"])
    run = fn -> for _n <- 1..count, do: query(sql, stacktrace) end

    case params["task"] do
      true -> run |> Task.async() |> Task.await()
      _inline -> run.()
    end

    {:noreply, socket}
  end

  # A real query on the SQLite test repo (EXPLAIN, ADR 08); errors are ignored.
  def handle_event("sqlite", %{"sql" => sql, "params" => params}, socket) do
    _ = DemoWeb.SQLiteRepo.query(sql, params)
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

  # A real query whose caller frame is gone (tail call) in a Task.async child.
  def handle_event("task_query", _params, socket) do
    fn -> DemoWeb.SQLiteRepo.all(users(1), stacktrace: true) end
    |> Task.async()
    |> Task.await()

    {:noreply, socket}
  end

  def handle_event("async_query", _params, socket) do
    {:noreply,
     start_async(socket, :load, fn -> DemoWeb.SQLiteRepo.all(users(2), stacktrace: true) end)}
  end

  # What a third party plugin would listen to (TestPlugins.Tabbed).
  def handle_event("echo", %{"value" => value}, socket) do
    :telemetry.execute([:pdt_test, :echo], %{}, %{value: value})
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_async(:load, _result, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns), do: ~H"<p>page</p>"

  defp users(n), do: Ecto.Query.from(u in "users", where: u.id == ^n, select: u.id)

  defp origin(nil), do: nil
  defp origin(file), do: [{DemoWeb.Posts, :load, 0, [file: String.to_charlist(file), line: 3]}]

  defp query(sql, stacktrace \\ nil) do
    :telemetry.execute(
      [:demo, :repo, :query],
      %{total_time: System.convert_time_unit(1, :millisecond, :native)},
      %{
        repo: DemoWeb.FakeRepo,
        query: sql,
        params: [],
        source: "users",
        result: {:ok, %{num_rows: 1}},
        stacktrace: stacktrace
      }
    )
  end
end
