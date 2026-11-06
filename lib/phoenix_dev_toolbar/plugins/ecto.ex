defmodule PhoenixDevToolbar.Plugins.Ecto do
  @moduledoc false
  # Built-in Ecto panel collector (ADR 02): one event per query of the repos in
  # `config :phoenix_dev_toolbar, repos: [MyApp.Repo]`, or in the plugin's own
  # `repos:` option (`{PhoenixDevToolbar.Plugins.Ecto, repos: [...]}`), which wins.
  # `n_plus_one:` (default 5) is the N+1 detector's threshold, `false` turns
  # it off (ADR 08).
  # `ecto_sql` stays an optional dependency: without repos, or without Ecto
  # loaded, this plugin attaches to nothing.

  use PhoenixDevToolbar.Plugin, id: :ecto, name: "Ecto"

  require Logger

  alias PhoenixDevToolbar.Components
  alias PhoenixDevToolbar.Context
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.NPlusOne
  alias PhoenixDevToolbar.Panels
  alias PhoenixDevToolbar.Truncate

  # Frames hidden from the query origin: the caller's code is what matters.
  @skip_frames [Ecto, DBConnection]
  @times [:query_time, :queue_time, :decode_time, :idle_time, :total_time]
  @n_plus_one 5

  @impl true
  def init(opts) do
    repos =
      Keyword.get_lazy(opts, :repos, fn ->
        Application.get_env(:phoenix_dev_toolbar, :repos, [])
      end)

    with {:ok, repos} <- repos(repos),
         {:ok, threshold} <- threshold(Keyword.get(opts, :n_plus_one, @n_plus_one)) do
      {:ok, %{repos: repos, n_plus_one: threshold}}
    end
  end

  defp repos(repos) when is_list(repos), do: {:ok, repos}

  defp repos(other),
    do: {:error, "repos must be a list of modules, got: #{inspect(other, limit: 5)}"}

  defp threshold(threshold) when (is_integer(threshold) and threshold >= 2) or threshold == false,
    do: {:ok, threshold}

  defp threshold(other),
    do: {:error, "n_plus_one must be an integer >= 2 or false, got: #{inspect(other, limit: 5)}"}

  @doc false
  # The detector's threshold in a config (the default for a config without one).
  @spec n_plus_one(term()) :: pos_integer() | false
  def n_plus_one(%{n_plus_one: threshold}), do: threshold
  def n_plus_one(_config), do: @n_plus_one

  @impl true
  def telemetry_events(%{repos: repos}) do
    for repo <- repos, prefix = telemetry_prefix(repo), do: prefix ++ [:query]
  end

  @impl true
  def panel, do: Panels.Ecto

  @impl true
  def summary_init(config),
    do: %{
      queries: 0,
      db_us: 0,
      slowest_us: 0,
      failed: 0,
      n_plus_one: NPlusOne.new(n_plus_one(config))
    }

  @impl true
  def summary_add(summary, %Event{kind: :query, duration: duration, data: data} = event) do
    duration = duration || 0
    {n_plus_one, _result} = NPlusOne.add(summary.n_plus_one, event)

    %{
      summary
      | queries: summary.queries + 1,
        db_us: summary.db_us + duration,
        slowest_us: max(summary.slowest_us, duration),
        failed: summary.failed + failed(data),
        n_plus_one: n_plus_one
    }
  end

  def summary_add(summary, %Event{}), do: summary

  @impl true
  def badges(%{queries: queries, db_us: db_us, failed: failed} = summary) do
    text = "#{queries} #{noun(queries)} · #{Components.duration(db_us)}"
    [%{id: "ecto-queries", text: text, level: queries_level(failed)} | n_plus_one_badge(summary)]
  end

  defp n_plus_one_badge(%{n_plus_one: n_plus_one}) do
    case NPlusOne.detected(n_plus_one) do
      0 ->
        []

      detected ->
        [
          %{
            id: "ecto-n-plus-one",
            text: "N+1 ×#{detected}",
            level: :warn,
            title: "The same query repeated in one callback: see the Ecto tab"
          }
        ]
    end
  end

  defp noun(1), do: "query"
  defp noun(_queries), do: "queries"

  defp queries_level(0), do: :info
  defp queries_level(_failed), do: :error

  defp failed(%{result: {:error, _}}), do: 1
  defp failed(_data), do: 0

  @impl true
  def collect(_event, {measurements, metadata}, %Context{source: source}) do
    data = %{
      repo: metadata[:repo],
      sql: metadata |> Map.get(:query) |> sql(),
      params: metadata |> params() |> Truncate.redact() |> Truncate.inspect_value(),
      source: metadata[:source],
      result: result(metadata[:result]),
      times: times(measurements),
      stacktrace: Truncate.stacktrace(metadata[:stacktrace], [metadata[:repo] | @skip_frames]),
      caller?: source == :caller
    }

    {:record, Event.new(:ecto, :query, data, duration: total(measurements))}
  end

  # Ecto derives the prefix from the repo name unless the repo config sets one;
  # `config/0` returns the resolved value. A repo that cannot be read is skipped.
  defp telemetry_prefix(repo) do
    with true <- Code.ensure_loaded?(repo) and function_exported?(repo, :config, 0),
         prefix when is_list(prefix) <- Keyword.get(repo.config(), :telemetry_prefix) do
      prefix
    else
      _ -> skip_repo(repo, "it is not an Ecto repo")
    end
  rescue
    exception -> skip_repo(repo, Exception.message(exception))
  end

  defp skip_repo(repo, why) do
    Logger.warning("[phoenix_dev_toolbar] ignoring repo #{inspect(repo)}: #{why}")
    nil
  end

  defp sql(query) when is_binary(query), do: Truncate.sql(query)
  defp sql(nil), do: nil
  defp sql(query), do: Truncate.inspect_value(query)

  defp params(%{cast_params: cast}) when is_list(cast), do: cast
  defp params(metadata), do: Map.get(metadata, :params, [])

  defp result({:ok, %{num_rows: rows}}), do: {:ok, rows}
  defp result({:ok, _other}), do: {:ok, nil}

  defp result({:error, %{__exception__: true} = error}),
    do: {:error, error |> Exception.message() |> Truncate.string()}

  defp result({:error, reason}), do: {:error, Truncate.inspect_value(reason)}
  defp result(_other), do: nil

  defp times(measurements) do
    for key <- @times, value = measurements[key], into: %{}, do: {key, Event.native_to_us(value)}
  end

  # Ecto's `total_time` is queue + query + decode (idle time is not part of it).
  defp total(%{total_time: total}), do: total

  defp total(measurements),
    do:
      [:queue_time, :query_time, :decode_time]
      |> Enum.map(&Map.get(measurements, &1, 0))
      |> Enum.sum()
end
