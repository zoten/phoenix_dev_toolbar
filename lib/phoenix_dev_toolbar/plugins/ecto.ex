defmodule PhoenixDevToolbar.Plugins.Ecto do
  @moduledoc false
  # Built-in Ecto panel collector (ADR 02): one event per query of the repos in
  # `config :phoenix_dev_toolbar, repos: [MyApp.Repo]`, or in the plugin's own
  # `repos:` option (`{PhoenixDevToolbar.Plugins.Ecto, repos: [...]}`), which wins.
  # `ecto_sql` stays an optional dependency: without repos, or without Ecto
  # loaded, this plugin attaches to nothing.

  use PhoenixDevToolbar.Plugin, id: :ecto, name: "Ecto"

  require Logger

  alias PhoenixDevToolbar.Context
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Truncate

  # Frames hidden from the query origin: the caller's code is what matters.
  @skip_frames [Ecto, DBConnection]
  @times [:query_time, :queue_time, :decode_time, :idle_time, :total_time]

  @impl true
  def init(opts) do
    case Keyword.get_lazy(opts, :repos, fn ->
           Application.get_env(:phoenix_dev_toolbar, :repos, [])
         end) do
      repos when is_list(repos) -> {:ok, %{repos: repos}}
      other -> {:error, "repos must be a list of modules, got: #{inspect(other, limit: 5)}"}
    end
  end

  @impl true
  def telemetry_events(%{repos: repos}) do
    for repo <- repos, prefix = telemetry_prefix(repo), do: prefix ++ [:query]
  end

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
