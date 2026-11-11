defmodule PhoenixDevToolbar.Plugins.Ecto do
  @moduledoc """
  The Ecto tab ([ADR 08](https://github.com/zoten/phoenix_dev_toolbar/blob/main/adr/08-query-diagnostics.md)): every query of the page,
  oldest first, with SQL, params, timings, rows and the code that ran it, N+1
  groups flagged above them, EXPLAIN for SELECTs and a JSON export. Part of
  `:defaults`.

      config :phoenix_dev_toolbar, repos: [MyApp.Repo]

  ## Options

  | Option | Type | Default |
  | --- | --- | --- |
  | `repos:` | list of repo modules | the top level `repos` config, else the `:ecto_repos` of the loaded applications |
  | `n_plus_one:` | integer `>= 2`, or `false` to turn the detector off | `5` |

  `repos:` in the plugin entry wins over the top level config:

      config :phoenix_dev_toolbar,
        plugins: [:defaults, {PhoenixDevToolbar.Plugins.Ecto, repos: [MyApp.Repo], n_plus_one: 3}]

  With no repos found, the tab stays empty and one warning names the config line.
  Set `stacktrace: true` in the repo's config to see where each query comes from.
  `ecto_sql` is an optional dependency: without it this plugin attaches to nothing.
  """

  # Built-in Ecto panel collector (ADR 02): one event per query of the repos in
  # `config :phoenix_dev_toolbar, repos: [MyApp.Repo]`, or in the plugin's own
  # `repos:` option (`{PhoenixDevToolbar.Plugins.Ecto, repos: [...]}`), which wins.
  # With neither, the repos are the `:ecto_repos` of the loaded applications,
  # read once in `init/1` (attach time, never in a telemetry handler).
  # `n_plus_one:` (default 5) is the N+1 detector's threshold, `false` turns
  # it off (ADR 08).
  # `ecto_sql` stays an optional dependency: without repos, or without Ecto
  # loaded, this plugin attaches to nothing.

  use PhoenixDevToolbar.Plugin, id: :ecto, name: "Ecto"

  require Logger

  alias PhoenixDevToolbar.Components
  alias PhoenixDevToolbar.Context
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Explain
  alias PhoenixDevToolbar.NPlusOne
  alias PhoenixDevToolbar.Panels
  alias PhoenixDevToolbar.Truncate

  # Frames hidden from the query origin: the caller's code is what matters.
  # Task and LiveView async plumbing is hidden too: the user's `fn -> Repo.all(q) end`
  # tail calls the repo, so these are all that is left of it (ADR 08).
  @skip_frames [Ecto, DBConnection, Task.Supervised, :proc_lib, Phoenix.LiveView.Async]
  @skip_names Enum.map(@skip_frames, &Atom.to_string/1)
  @times [:query_time, :queue_time, :decode_time, :idle_time, :total_time]
  @n_plus_one 5

  @impl PhoenixDevToolbar.Plugin
  def init(opts) do
    repos = Keyword.get_lazy(opts, :repos, &configured_or_declared_repos/0)

    with {:ok, repos} <- repos(repos),
         {:ok, threshold} <- threshold(Keyword.get(opts, :n_plus_one, @n_plus_one)) do
      {:ok, %{repos: repos, n_plus_one: threshold}}
    end
  end

  defp configured_or_declared_repos do
    case Application.get_env(:phoenix_dev_toolbar, :repos) do
      nil -> declared_repos()
      repos -> repos
    end
  end

  # The repos the host declares with `config :my_app, ecto_repos: [...]`.
  defp declared_repos do
    repos =
      for {app, _description, _version} <- Application.loaded_applications(),
          repo <- List.wrap(Application.get_env(app, :ecto_repos, [])),
          is_atom(repo),
          uniq: true,
          do: repo

    maybe_warn_no_repos(repos)
    repos
  end

  defp maybe_warn_no_repos([]), do: warn_no_repos(Code.ensure_loaded?(Ecto.Adapters.SQL))
  defp maybe_warn_no_repos(_repos), do: :ok

  defp warn_no_repos(false), do: :ok

  defp warn_no_repos(true) do
    Logger.warning(
      "[phoenix_dev_toolbar] no Ecto repos found: the Ecto tab stays empty. " <>
        "Add `config :phoenix_dev_toolbar, repos: [MyApp.Repo]` to config/dev.exs"
    )
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

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(%{repos: repos}) do
    for repo <- repos, prefix = telemetry_prefix(repo), do: List.insert_at(prefix, -1, :query)
  end

  @impl PhoenixDevToolbar.Plugin
  def panel, do: Panels.Ecto

  @impl PhoenixDevToolbar.Plugin
  def summary_init(config),
    do: %{
      queries: 0,
      db_us: 0,
      slowest_us: 0,
      failed: 0,
      n_plus_one: NPlusOne.new(n_plus_one(config))
    }

  @impl PhoenixDevToolbar.Plugin
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

  def summary_add(summary, %Event{kind: :n_plus_one_cleared} = event) do
    {n_plus_one, _result} = NPlusOne.add(summary.n_plus_one, event)
    %{summary | n_plus_one: n_plus_one}
  end

  def summary_add(summary, %Event{}), do: summary

  @impl PhoenixDevToolbar.Plugin
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

  # Stored params never exceed this many bytes (ADR 03).
  @params_bytes 2048

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, {measurements, metadata}, %Context{source: source}) do
    raw_sql = Map.get(metadata, :query)
    sql = sql(raw_sql)

    data = %{
      repo: metadata[:repo],
      sql: sql,
      params: metadata |> params() |> Truncate.preview(@params_bytes),
      source: metadata[:source],
      result: result(metadata[:result]),
      times: times(measurements),
      stacktrace: Truncate.stacktrace(metadata[:stacktrace], [metadata[:repo] | @skip_frames]),
      caller?: source == :caller,
      initial_call: initial_call(source),
      # Raw params for EXPLAIN (ADR 08): never rendered.
      explain: Explain.capture(raw_sql, sql, metadata[:params])
    }

    {:record, Event.new(:ecto, :query, data, duration: total(measurements))}
  end

  # The function a Task or start_async child was started with (ADR 08): its
  # origin when the stacktrace has no app frame left. One pdict read, for
  # caller-sourced queries only; nil for plumbing modules.
  defp initial_call(:caller) do
    case Process.get(:"$initial_call") do
      {module, fun, arity} when is_atom(module) and is_atom(fun) and is_integer(arity) ->
        initial_call(module, fun, arity)

      _other ->
        nil
    end
  end

  defp initial_call(_source), do: nil

  defp initial_call(module, fun, arity) do
    name = Atom.to_string(module)

    case Enum.any?(@skip_names, &(name == &1 or String.starts_with?(name, &1 <> "."))) do
      true -> nil
      false -> module |> Exception.format_mfa(fun, arity) |> Truncate.string()
    end
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
