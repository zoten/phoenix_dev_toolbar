defmodule PdtExamples.Oban do
  @moduledoc """
  Example plugin (ADR 05): the Oban jobs a page enqueued.

  Oban inserts a job in the caller's process, inside the
  `[:oban, :engine, :insert_job | :insert_all_jobs, ...]` spans, so the toolbar
  attributes the insert to the page (a LiveView event, a request). Jobs
  *run* in Oban's own processes, which belong to no page: execution is not
  shown here.

      config :phoenix_dev_toolbar,
        plugins: [:defaults, {PdtExamples.Oban, queues: [:default]}]
  """

  use PhoenixDevToolbar.Plugin, id: :oban, name: "Oban"

  alias PhoenixDevToolbar.Context
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Truncate

  @insert [:oban, :engine, :insert_job, :stop]
  @insert_failed [:oban, :engine, :insert_job, :exception]
  @insert_all [:oban, :engine, :insert_all_jobs, :stop]
  # Workers listed for one insert_all.
  @workers 5

  # Queues are compared as strings, the way Oban stores them.
  @impl true
  def init(opts) do
    case Keyword.get(opts, :queues, :all) do
      :all -> {:ok, %{queues: :all}}
      queues when is_list(queues) -> {:ok, %{queues: Enum.map(queues, &to_string/1)}}
      other -> {:error, "queues must be :all or a list, got: #{inspect(other, limit: 5)}"}
    end
  end

  @impl true
  def telemetry_events(_config), do: [@insert, @insert_failed, @insert_all]

  # Runs in the host process that inserted: bounded values only, no calls.
  @impl true
  def collect(@insert, {measurements, %{job: %{queue: queue} = job}}, %Context{config: config}) do
    case wanted?(config, queue) do
      true ->
        {:record, Event.new(:oban, :inserted, job_data(job), duration: measurements[:duration])}

      false ->
        :skip
    end
  end

  # An insert that returned an error (a changeset): no job in the metadata.
  def collect(@insert, {measurements, _metadata}, _context),
    do: {:record, Event.new(:oban, :rejected, %{}, duration: measurements[:duration])}

  def collect(@insert_failed, {measurements, metadata}, _context) do
    data = %{error: Truncate.banner(metadata.kind, metadata.reason)}
    {:record, Event.new(:oban, :failed, data, duration: measurements[:duration])}
  end

  def collect(@insert_all, {measurements, %{jobs: jobs}}, %Context{config: config}) do
    jobs = Enum.filter(jobs, &wanted?(config, &1.queue))

    data = %{
      count: length(jobs),
      workers: jobs |> Enum.map(&text(&1.worker, 128)) |> Enum.uniq() |> Enum.take(@workers)
    }

    {:record, Event.new(:oban, :inserted_all, data, duration: measurements[:duration])}
  end

  def collect(_event, _payload, _context), do: :skip

  @impl true
  def panel, do: PdtExamples.ObanPanel

  @impl true
  def summary_init(_config), do: %{jobs: 0, failed: 0}

  @impl true
  # A unique conflict returns the existing job: nothing new was enqueued.
  def summary_add(summary, %Event{kind: :inserted, data: %{conflict?: true}}), do: summary
  def summary_add(summary, %Event{kind: :inserted}), do: %{summary | jobs: summary.jobs + 1}

  def summary_add(summary, %Event{kind: :inserted_all, data: %{count: n}}),
    do: %{summary | jobs: summary.jobs + n}

  def summary_add(summary, %Event{kind: kind}) when kind in [:failed, :rejected],
    do: %{summary | failed: summary.failed + 1}

  def summary_add(summary, _event), do: summary

  @impl true
  def badges(%{jobs: 0, failed: 0}), do: []

  def badges(%{jobs: jobs, failed: failed}),
    do: [
      %{
        id: "oban-jobs",
        text: "#{jobs} #{noun(jobs)} enqueued",
        level: level(failed),
        title: title(failed)
      }
    ]

  defp job_data(job) do
    %{
      worker: text(job.worker, 128),
      queue: text(job.queue, 64),
      # preview/2 redacts and cuts what it does not walk, however deep.
      args: Truncate.preview(job.args, 512),
      state: job.state,
      conflict?: Map.get(job, :conflict?, false)
    }
  end

  # Never raise in the host process on an unexpected value.
  defp text(value, limit) when is_binary(value), do: Truncate.string(value, limit)
  defp text(value, _limit), do: Truncate.inspect_value(value)

  defp wanted?(%{queues: :all}, _queue), do: true
  defp wanted?(%{queues: queues}, queue), do: queue in queues

  defp noun(1), do: "job"
  defp noun(_jobs), do: "jobs"

  defp level(0), do: :info
  defp level(_failed), do: :error

  defp title(0), do: "Jobs inserted by this page (not their execution)"
  defp title(1), do: "1 insert failed"
  defp title(failed), do: "#{failed} inserts failed"
end
