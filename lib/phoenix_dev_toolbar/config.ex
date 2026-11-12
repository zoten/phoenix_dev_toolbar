defmodule PhoenixDevToolbar.Config do
  @moduledoc false
  # Plugin registration (ADR 05): expands `:defaults`, applies overrides and
  # exclusions, validates every entry. Store limits (ADR 03): validates the
  # overrides. Never raises: an invalid entry is logged and skipped, the host
  # application always boots.

  require Logger

  alias PhoenixDevToolbar.ClientMatch
  alias PhoenixDevToolbar.Plugin
  alias PhoenixDevToolbar.Plugins

  @defaults [Plugins.Ecto, Plugins.Request, Plugins.LiveView, Plugins.Process, Plugins.System]

  @type entry :: {module(), keyword()}

  @typedoc "Resolved `stack_args:`: the per frame byte cap, lowered extra keys, rules and the agents gate."
  @type stack_args :: %{
          bytes: pos_integer(),
          redact: [String.t()],
          rules: %{
            (module() | {module(), atom()} | {module(), atom(), non_neg_integer()}) =>
              :hide | [String.t()]
          },
          agents: boolean()
        }

  @stack_args_bytes 512
  # `:crypto` calls carry keys and data as bare binaries, which no key name can
  # redact: hidden unless the developer writes a `:crypto` rule (ADR 03).
  @default_rules %{crypto: :hide}

  # Limits that may be 0 (expire at once); every other limit is a positive cap.
  @zero_limits [:ttl_ms]

  @doc "The built-in plugins `:defaults` expands to."
  @spec defaults() :: [module()]
  def defaults, do: @defaults

  @doc """
  Whether the toolbar reserves its page space by default (ADR 04): `reserve_space:`,
  `true` unless set to `false`. The dock menu's toggle overrides it per browser.
  """
  @spec reserve_space?() :: boolean()
  def reserve_space?, do: Application.get_env(:phoenix_dev_toolbar, :reserve_space, true) != false

  @type pill_corner :: :bottom_right | :bottom_left | :top_right | :top_left

  @corners [:bottom_right, :bottom_left, :top_right, :top_left]
  @modifier_order ["ctrl", "alt", "shift", "meta"]
  @modifier_aliases %{
    "ctrl" => "ctrl",
    "control" => "ctrl",
    "alt" => "alt",
    "option" => "alt",
    "shift" => "shift",
    "meta" => "meta",
    "cmd" => "meta"
  }
  @shortcut_keys Enum.map(~w(a b c d e f g h i j k l m n o p q r s t u v w x y z), & &1) ++
                   Enum.map(0..9, &Integer.to_string/1) ++
                   Enum.map(1..12, &("f" <> Integer.to_string(&1)))

  @doc """
  The corner the collapsed pill sits in (ADR 04): `pill_corner:`, one of `:bottom_right`
  (the default), `:bottom_left`, `:top_right` or `:top_left`. Unset or invalid is
  `:bottom_right`. Never logs (`warn_ui/0` does).
  """
  @spec pill_corner() :: pill_corner()
  def pill_corner do
    case Application.get_env(:phoenix_dev_toolbar, :pill_corner) do
      corner when corner in @corners -> corner
      _unset_or_invalid -> :bottom_right
    end
  end

  @default_inspect_nodes 500
  @inspect_nodes_range 50..10_000

  @doc """
  How many DOM nodes the element inspector may visit looking for the component frames
  of a picked element (ADR 16): `inspect_nodes:`, an integer from 50 to 10_000, `500`
  by default. Raise it for very long lists or tables. Unset or invalid is `500`.
  Never logs (`warn_ui/0` does).
  """
  @spec inspect_nodes() :: 50..10_000
  def inspect_nodes do
    case Application.get_env(:phoenix_dev_toolbar, :inspect_nodes) do
      nodes when is_integer(nodes) and nodes in @inspect_nodes_range -> nodes
      _unset_or_invalid -> @default_inspect_nodes
    end
  end

  @doc """
  The keyboard shortcut that toggles the toolbar (ADR 04): `shortcut:`, written like
  `"ctrl+shift+d"`, returned in canonical form (lowercase, modifiers ordered `ctrl`,
  `alt`, `shift`, `meta`). Accepts any case, spaces around `+`, and the aliases `cmd`
  (`meta`), `control` (`ctrl`) and `option` (`alt`). Needs at least one modifier and
  exactly one key (`a` to `z`, `0` to `9`, `f1` to `f12`). Unset, invalid or not a
  string is `nil`. Never logs (`warn_ui/0` does).
  """
  @spec shortcut() :: String.t() | nil
  def shortcut, do: :phoenix_dev_toolbar |> Application.get_env(:shortcut) |> canonical_shortcut()

  defp canonical_shortcut(value) when is_binary(value) do
    case String.valid?(value) do
      true ->
        value
        |> String.downcase()
        |> String.split("+")
        |> Enum.map(&String.trim/1)
        |> shortcut_parts()

      false ->
        nil
    end
  end

  defp canonical_shortcut(_not_a_string), do: nil

  defp shortcut_parts(parts) do
    {mods, [key]} = Enum.split(parts, -1)
    mods = Enum.map(mods, &Map.get(@modifier_aliases, &1))

    case mods != [] and key in @shortcut_keys and not Enum.member?(mods, nil) do
      true -> join_shortcut(mods, key)
      false -> nil
    end
  end

  defp join_shortcut(mods, key) do
    ordered = Enum.filter(@modifier_order, &(&1 in mods))
    Enum.join(ordered, "+") <> "+" <> key
  end

  @doc "Logs, at boot, an invalid `pill_corner:`, `shortcut:` or `inspect_nodes:` and what is used instead."
  @spec warn_ui() :: :ok
  def warn_ui do
    warn_pill_corner(Application.get_env(:phoenix_dev_toolbar, :pill_corner))
    warn_shortcut(Application.get_env(:phoenix_dev_toolbar, :shortcut))
    warn_inspect_nodes(Application.get_env(:phoenix_dev_toolbar, :inspect_nodes))
  end

  defp warn_inspect_nodes(nil), do: :ok
  defp warn_inspect_nodes(nodes) when is_integer(nodes) and nodes in @inspect_nodes_range, do: :ok

  defp warn_inspect_nodes(invalid) do
    Logger.warning(
      "[phoenix_dev_toolbar] invalid inspect_nodes: #{inspect(invalid, limit: 5)}, " <>
        "expected an integer from 50 to 10000. Using #{@default_inspect_nodes}."
    )
  end

  defp warn_pill_corner(nil), do: :ok
  defp warn_pill_corner(corner) when corner in @corners, do: :ok

  defp warn_pill_corner(invalid) do
    Logger.warning(
      "[phoenix_dev_toolbar] invalid pill_corner: #{inspect(invalid, limit: 5)}, " <>
        "expected :bottom_right, :bottom_left, :top_right or :top_left. Using :bottom_right."
    )
  end

  defp warn_shortcut(nil), do: :ok

  defp warn_shortcut(value) do
    case canonical_shortcut(value) do
      nil ->
        Logger.warning(
          "[phoenix_dev_toolbar] invalid shortcut: #{inspect(value, limit: 5)}, " <>
            "expected at least one modifier (ctrl, alt, shift, meta) and one key " <>
            "(a-z, 0-9, f1-f12), like \"ctrl+shift+d\". Using no shortcut."
        )

      _valid ->
        :ok
    end
  end

  @type mcp_mode :: :off | :local | {:list, [ClientMatch.entry()]} | :any

  @doc """
  Whether the MCP endpoint is served: `mcp:`, on unless set to `false`.
  """
  @spec mcp?() :: boolean()
  def mcp?, do: mcp() != :off

  @doc """
  Who may reach MCP (ADR 15): `false` is `:off`; `true`, unset, `[clients: :local]`
  and anything invalid are `:local`; `[clients: :any]` is `:any`; `[clients: list]`
  is `{:list, entries}` with the valid entries parsed. Never logs (`warn_mcp/0` does).
  """
  @spec mcp() :: mcp_mode()
  def mcp, do: :phoenix_dev_toolbar |> Application.get_env(:mcp, true) |> mcp_mode()

  defp mcp_mode(false), do: :off
  defp mcp_mode(clients: :any), do: :any

  defp mcp_mode(clients: list) when is_list(list) do
    case proper_list?(list) do
      true -> {:list, parsed_clients(list)}
      false -> :local
    end
  end

  defp mcp_mode(_local_or_invalid), do: :local

  defp parsed_clients(list),
    do: for(entry <- list, {:ok, parsed} <- [ClientMatch.parse(entry)], do: parsed)

  @doc "Logs, at boot, an invalid `mcp:` shape, invalid `clients:` entries and `clients: :any`."
  @spec warn_mcp() :: :ok
  def warn_mcp, do: :phoenix_dev_toolbar |> Application.get_env(:mcp, true) |> warn_mcp_value()

  defp warn_mcp_value(value) when is_boolean(value), do: :ok
  defp warn_mcp_value(clients: :local), do: :ok

  defp warn_mcp_value(clients: :any) do
    Logger.warning(
      "[phoenix_dev_toolbar] mcp: [clients: :any]: anyone who reaches this dev server " <>
        "can read the captured data over MCP"
    )
  end

  defp warn_mcp_value(clients: list) when is_list(list) do
    case proper_list?(list) do
      true -> warn_invalid_clients(list)
      false -> warn_mcp_value(:improper_list)
    end
  end

  defp warn_mcp_value(invalid) do
    Logger.warning(
      "[phoenix_dev_toolbar] invalid mcp: #{inspect(invalid, limit: 5)}, " <>
        "expected true, false, [clients: :local], [clients: :any] or [clients: [\"10.0.0.0/8\"]]. " <>
        "Using true."
    )
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_improper), do: false

  defp warn_invalid_clients(list) do
    case Enum.reject(list, &match?({:ok, _parsed}, ClientMatch.parse(&1))) do
      [] ->
        :ok

      invalid ->
        Logger.warning(
          "[phoenix_dev_toolbar] invalid mcp clients ignored: #{inspect(invalid, limit: 5, printable_limit: 80)}"
        )
    end
  end

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
  not a positive integer (or 0 for `ttl_ms`) is logged and
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

  @doc """
  Keeps the `redact:` entries that are binaries or atoms; anything else would
  raise in `to_string/1` on the collect path. One warning for the dropped ones.
  """
  @spec redact(term()) :: [String.t() | atom()]
  def redact(configured) do
    {valid, dropped} =
      configured |> List.wrap() |> Enum.split_with(&(is_binary(&1) or is_atom(&1)))

    maybe_warn_redact(dropped)
    valid
  end

  @doc """
  Resolves `stack_args:` (ADR 03) into `t:stack_args/0`, or nil when call
  arguments stay out of crash stacktraces (the default: `false`, absent or
  invalid). `true` means all defaults. A bad entry is logged and falls back,
  never raises, never makes atoms. Rule keys are the modules and functions the
  developer wrote; rule redact keys are lowered strings.
  """
  @spec stack_args(term()) :: stack_args() | nil
  def stack_args(value) when value in [nil, false], do: nil
  def stack_args(true), do: stack_args([])

  def stack_args(opts) when is_list(opts) do
    case Keyword.keyword?(opts) do
      true -> resolve_stack_args(opts)
      false -> bad_stack_args(opts)
    end
  end

  def stack_args(other), do: bad_stack_args(other)

  defp bad_stack_args(value) do
    warn("`stack_args` must be a boolean or a keyword list, got #{inspect(value, limit: 5)}: off")
    nil
  end

  defp resolve_stack_args(opts) do
    %{
      bytes: stack_args_bytes(Keyword.get(opts, :bytes, @stack_args_bytes)),
      redact: opts |> Keyword.get(:redact, []) |> stack_args_keys("redact"),
      rules: opts |> Keyword.get(:rules, []) |> stack_args_rules(),
      agents: stack_args_agents(Keyword.get(opts, :agents, false))
    }
  end

  defp stack_args_bytes(bytes) when is_integer(bytes) and bytes in 64..8192, do: bytes

  defp stack_args_bytes(other) do
    _ =
      warn(
        "`stack_args` `bytes` must be an integer from 64 to 8192, got " <>
          "#{inspect(other, limit: 5)}: using #{@stack_args_bytes}"
      )

    @stack_args_bytes
  end

  defp stack_args_agents(agents) when is_boolean(agents), do: agents

  defp stack_args_agents(other) do
    _ = warn("`stack_args` `agents` must be a boolean, got #{inspect(other, limit: 5)}: false")
    false
  end

  # Lowered strings, as `Truncate` compares them.
  defp stack_args_keys(keys, where) when is_list(keys) do
    case proper_list?(keys) do
      true -> lowered_keys(keys, where)
      false -> stack_args_keys(:improper, where)
    end
  end

  defp stack_args_keys(other, where) do
    _ =
      warn(
        "`stack_args` #{where} must be a proper list, got #{inspect(other, limit: 5)}: ignored"
      )

    []
  end

  # An empty key would match every key name: dropped with the invalid ones.
  defp lowered_keys(keys, where) do
    {valid, dropped} = Enum.split_with(keys, &key_entry?/1)

    case dropped do
      [] -> :ok
      _ -> warn("ignoring `stack_args` #{where} entries #{inspect(dropped, limit: 5)}")
    end

    Enum.map(valid, &(&1 |> to_string() |> String.downcase()))
  end

  defp key_entry?(key) when is_binary(key), do: key != ""
  defp key_entry?(key) when is_atom(key), do: key not in [nil, :""]
  defp key_entry?(_key), do: false

  defp stack_args_rules(rules) when is_list(rules) do
    case proper_list?(rules) do
      true -> rules |> parsed_rules() |> then(&Map.merge(@default_rules, &1))
      false -> stack_args_rules(:improper)
    end
  end

  defp stack_args_rules(other) do
    _ = warn("`stack_args` rules must be a proper list, got #{inspect(other, limit: 5)}: ignored")
    @default_rules
  end

  defp parsed_rules(rules) do
    Enum.reduce(rules, %{}, fn rule, acc ->
      case stack_args_rule(rule) do
        {:ok, key, action} ->
          Map.put(acc, key, action)

        :error ->
          _ =
            warn(
              "ignoring `stack_args` rule #{inspect(rule, limit: 5)}: expected " <>
                "{Module | {Module, fun} | {Module, fun, arity}, :hide | [key]}"
            )

          acc
      end
    end)
  end

  defp stack_args_rule({key, action}) do
    with true <- rule_key?(key), {:ok, action} <- rule_action(action) do
      {:ok, key, action}
    else
      _ -> :error
    end
  end

  defp stack_args_rule(_rule), do: :error

  defp rule_key?(module) when is_atom(module), do: true
  defp rule_key?({module, fun}), do: is_atom(module) and is_atom(fun)

  defp rule_key?({module, fun, arity}),
    do: is_atom(module) and is_atom(fun) and is_integer(arity) and arity >= 0

  defp rule_key?(_key), do: false

  defp rule_action(:hide), do: {:ok, :hide}

  defp rule_action(keys) when is_list(keys) do
    case proper_list?(keys) and Enum.all?(keys, &key_entry?/1) do
      true -> {:ok, Enum.map(keys, &(&1 |> to_string() |> String.downcase()))}
      false -> :error
    end
  end

  defp rule_action(_action), do: :error

  @doc """
  Keeps the `allowed_origins:` entries an `Origin` header can match (`origin/1`),
  one warning per dropped entry: a typo would otherwise only show as a refused
  socket.
  """
  @spec allowed_origins(term()) :: [String.t()]
  def allowed_origins(configured) do
    configured
    |> List.wrap()
    |> Enum.filter(fn entry ->
      case origin(entry) do
        {:ok, _origin} ->
          true

        :error ->
          _ =
            warn(
              "ignoring `allowed_origins` entry #{inspect(entry, limit: 5)}: expected " <>
                "scheme://host[:port] as the browser shows it (http or https, no paths, " <>
                "no wildcards)"
            )

          false
      end
    end)
  end

  @doc """
  An origin as `{scheme, host, port}`, the host downcased and a default port
  filled in, so `https://a` and `https://a:443` are the same, as for the
  browser. Only what an `Origin` header can carry: http or https, a host, no
  user info, path (a bare `/` aside), query or fragment, no `*`.
  """
  @spec origin(term()) :: {:ok, {String.t(), String.t(), :inet.port_number()}} | :error
  def origin(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host, port: port, path: path, userinfo: nil, query: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             path in [nil, "/"] ->
        bare_origin(origin, {scheme, String.downcase(host), port})

      _other ->
        :error
    end
  end

  def origin(_origin), do: :error

  # URI drops an empty fragment ("#"): refuse any.
  defp bare_origin(origin, {_scheme, host, _port} = parsed) do
    case String.contains?(origin, "#") or String.contains?(host, "*") do
      true -> :error
      false -> {:ok, parsed}
    end
  end

  defp maybe_warn_redact([]), do: :ok

  defp maybe_warn_redact(dropped) do
    _ = warn("ignoring `redact` entries #{inspect(dropped, limit: 5)}: expected strings or atoms")
    :ok
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
