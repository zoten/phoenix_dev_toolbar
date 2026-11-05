defmodule PhoenixDevToolbar.Config do
  @moduledoc false
  # Plugin registration (ADR 05): expands `:defaults`, applies overrides and
  # exclusions, validates every entry. Never raises: an invalid entry is logged
  # and skipped, the host application always boots.

  require Logger

  alias PhoenixDevToolbar.Plugins

  @defaults [Plugins.Request, Plugins.Ecto, Plugins.LiveView]
  # Event plugin ids the toolbar uses itself (client events of the LiveView tab).
  @reserved_ids [:client]

  @type entry :: {module(), keyword()}

  @doc "The built-in plugins `:defaults` expands to."
  @spec defaults() :: [module()]
  def defaults, do: @defaults

  @doc "The configured plugins, expanded and validated, in order."
  @spec plugins() :: [entry()]
  def plugins, do: :phoenix_dev_toolbar |> Application.get_env(:plugins, [:defaults]) |> expand()

  @doc """
  Expands a `plugins:` value. Entries: `:defaults`, `Module`, `{Module, opts}`,
  `{:exclude, Module}`. A module listed twice keeps its first position and its
  last options (so a built-in listed with options overrides `:defaults`).
  """
  @spec expand(term()) :: [entry()]
  def expand(entries) when is_list(entries) do
    excluded = for {:exclude, module} <- entries, do: module

    entries
    |> Enum.flat_map(&entry/1)
    |> Enum.reject(fn {module, _opts} -> module in excluded end)
    |> merge_duplicates()
    |> Enum.filter(&valid?/1)
    |> unique_ids()
  end

  def expand(other) do
    warn("`plugins` must be a list, got #{inspect(other, limit: 5)}: using [:defaults]")
    expand([:defaults])
  end

  defp entry(:defaults), do: Enum.map(@defaults, &{&1, []})
  defp entry({:exclude, module}) when is_atom(module), do: []
  defp entry({module, opts}) when is_atom(module) and is_list(opts), do: [{module, opts}]
  defp entry(module) when is_atom(module), do: [{module, []}]

  defp entry(other) do
    warn("ignoring plugin entry #{inspect(other, limit: 5)}: expected Module or {Module, opts}")
    []
  end

  defp merge_duplicates(entries) do
    last_opts = Map.new(entries)

    entries
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn {module, _} -> {module, last_opts[module]} end)
  end

  defp valid?({module, _opts}) do
    check(module)
  rescue
    exception -> warn("ignoring plugin #{inspect(module)}: #{Exception.message(exception)}")
  end

  defp check(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        warn("ignoring plugin #{inspect(module)}: module not available")

      not plugin?(module) ->
        warn("ignoring plugin #{inspect(module)}: it does not implement PhoenixDevToolbar.Plugin")

      not is_atom(module.id()) or module.id() in @reserved_ids ->
        warn("ignoring plugin #{inspect(module)}: id #{inspect(module.id())} is reserved")

      true ->
        true
    end
  end

  defp plugin?(module) do
    Enum.all?([id: 0, name: 0, telemetry_events: 1, collect: 3], fn {name, arity} ->
      function_exported?(module, name, arity)
    end)
  end

  defp unique_ids(entries) do
    {kept, _seen} =
      Enum.flat_map_reduce(entries, %{}, fn {module, _opts} = entry, seen ->
        id = module.id()

        case seen do
          %{^id => first} ->
            warn(
              "ignoring plugin #{inspect(module)}: id #{inspect(id)} is taken by #{inspect(first)}"
            )

            {[], seen}

          _ ->
            {[entry], Map.put(seen, id, module)}
        end
      end)

    kept
  end

  defp warn(message) do
    Logger.warning("[phoenix_dev_toolbar] " <> message)
    false
  end
end
