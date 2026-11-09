defmodule PhoenixDevToolbar.Config do
  @moduledoc false
  # Plugin registration (ADR 05): expands `:defaults`, applies overrides and
  # exclusions, validates every entry. Store limits (ADR 03): validates the
  # overrides. Never raises: an invalid entry is logged and skipped, the host
  # application always boots.

  require Logger

  alias PhoenixDevToolbar.Plugin
  alias PhoenixDevToolbar.Plugins

  @defaults [Plugins.Ecto, Plugins.Request, Plugins.LiveView, Plugins.Process, Plugins.System]

  @type entry :: {module(), keyword()}

  # Limits that may be 0 (expire at once); every other limit is a positive cap.
  @zero_limits [:ttl_ms, :down_grace_ms]

  @doc "The built-in plugins `:defaults` expands to."
  @spec defaults() :: [module()]
  def defaults, do: @defaults

  @doc """
  Whether the toolbar reserves its page space by default (ADR 04): `reserve_space:`,
  `true` unless set to `false`. The dock menu's toggle overrides it per browser.
  """
  @spec reserve_space?() :: boolean()
  def reserve_space?, do: Application.get_env(:phoenix_dev_toolbar, :reserve_space, true) != false

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
    |> Enum.flat_map(&identify/1)
    |> unique_ids()
  end

  def expand(other) do
    warn("`plugins` must be a list, got #{inspect(other, limit: 5)}: using [:defaults]")
    expand([:defaults])
  end

  @doc """
  Merges `limits:` overrides into `defaults`. An unknown key or a value that is
  not a positive integer (or 0 for `ttl_ms` and `down_grace_ms`) is logged and
  keeps the default: `:infinity` would silently disable a cap.
  """
  @spec limits(term(), %{atom() => non_neg_integer()}) :: %{atom() => non_neg_integer()}
  def limits(overrides, defaults) when is_list(overrides) do
    Enum.reduce(overrides, defaults, fn override, acc -> put_limit(override, acc) end)
  end

  def limits(other, defaults) do
    warn("`limits` must be a keyword list, got #{inspect(other, limit: 5)}: using the defaults")
    defaults
  end

  defp put_limit({key, value} = override, acc) when is_map_key(acc, key) do
    case valid_limit?(key, value) do
      true -> Map.put(acc, key, value)
      false -> skip_limit(override, "expected #{limit_kind(key)}", acc)
    end
  end

  defp put_limit(override, acc), do: skip_limit(override, "unknown limit", acc)

  defp valid_limit?(key, value) when key in @zero_limits, do: is_integer(value) and value >= 0
  defp valid_limit?(_key, value), do: is_integer(value) and value > 0

  defp limit_kind(key) when key in @zero_limits, do: "a non-negative integer"
  defp limit_kind(_key), do: "a positive integer"

  defp skip_limit(override, why, acc) do
    warn("ignoring limit #{inspect(override, limit: 5)}: #{why}")
    acc
  end

  defp entry(:defaults), do: Enum.map(@defaults, &{&1, []})
  defp entry({:exclude, module}) when is_atom(module), do: []

  defp entry({:exclude, other}) do
    warn("ignoring #{inspect({:exclude, other}, limit: 5)}: expected {:exclude, Module}")
    []
  end

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

  # Plugin code runs here, during the host's application start: `id/0` is
  # called once, and any raise, throw or exit only skips that plugin.
  defp identify({module, opts}) do
    case check(module) do
      {:ok, id} -> [{module, opts, id}]
      {:error, why} -> skip(module, why)
    end
  catch
    kind, reason -> skip(module, Exception.format_banner(kind, reason))
  end

  defp check(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, "module not available"}

      not plugin?(module) ->
        {:error, "it does not implement PhoenixDevToolbar.Plugin"}

      not summary?(module) ->
        {:error, "define all of summary_init/1, summary_add/2, badges/1 or none"}

      not panel?(module) ->
        {:error, "panel/0 must return a module that uses PhoenixDevToolbar.Panel"}

      not is_binary(module.name()) ->
        {:error, "name/0 must return a string"}

      true ->
        check_id(module.id())
    end
  end

  defp check_id(id) when is_atom(id) and id not in [nil, true, false] do
    case id in Plugin.reserved_ids() do
      true -> {:error, "id #{inspect(id)} is reserved"}
      false -> {:ok, id}
    end
  end

  defp check_id(id), do: {:error, "id/0 must return an atom, got: #{inspect(id, limit: 5)}"}

  defp skip(module, why) do
    warn("ignoring plugin #{inspect(module)}: #{why}")
    []
  end

  defp summary?(module) do
    [summary_init: 1, summary_add: 2, badges: 1]
    |> Enum.map(fn {name, arity} -> function_exported?(module, name, arity) end)
    |> Enum.uniq()
    |> length() == 1
  end

  defp panel?(module) do
    case function_exported?(module, :panel, 0) do
      true ->
        panel = module.panel()

        is_atom(panel) and Code.ensure_loaded?(panel) and
          function_exported?(panel, :handle_reset, 2)

      false ->
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
      Enum.flat_map_reduce(entries, %{}, fn {module, opts, id}, seen ->
        case seen do
          %{^id => first} ->
            warn(
              "ignoring plugin #{inspect(module)}: id #{inspect(id)} is taken by #{inspect(first)}"
            )

            {[], seen}

          _ ->
            {[{module, opts}], Map.put(seen, id, module)}
        end
      end)

    kept
  end

  defp warn(message) do
    Logger.warning("[phoenix_dev_toolbar] " <> message)
    false
  end
end
