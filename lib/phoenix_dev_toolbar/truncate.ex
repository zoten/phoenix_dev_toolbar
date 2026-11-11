defmodule PhoenixDevToolbar.Truncate do
  @moduledoc """
  Bounds payloads before they are stored ([ADR 03](https://github.com/zoten/phoenix_dev_toolbar/blob/main/adr/03-event-storage.md)): plugins use these helpers
  in `c:PhoenixDevToolbar.Plugin.collect/3`, which runs inside host processes.
  Every function is pure, cheap on small inputs and bounded on large ones.
  `redact/2` hides the values of sensitive keys (`config :phoenix_dev_toolbar,
  redact: [...]`, by default keys containing "password", "token" or "secret").
  """

  @inspect_opts [limit: 50, printable_limit: 1024, charlists: :as_lists]
  @sql_limit 8192
  @string_limit 2048
  @frames 10
  @redacted "[REDACTED]"
  @list_items 50
  # Total nodes `redact/2` walks, whatever the value's shape: 50 entries per
  # container alone would allow 50^depth nodes. The budget also bounds the
  # recursion depth (one node per level at least), so there is no depth cap.
  @redact_nodes 1000
  # Key names are matched on their first bytes only (a key can be a huge binary).
  @key_prefix 256
  @default_redact ["password", "token", "secret"]
  @own_frames [:telemetry, PhoenixDevToolbar]
  # Assigns diff of one callback (ADR 03): about 4 KB at most.
  @change_keys 20
  @change_values 10
  @change_inspect [limit: 20, printable_limit: 256, charlists: :as_lists]
  @change_bytes 360
  # A preview walks at most @preview_nodes nodes and @preview_width items per
  # container, whatever the value's size: assigns can be huge (ADR 03).
  @preview_nodes 200
  @preview_width 20
  @cut "…"
  @snapshot_keys 100

  @type changes :: %{keys: [term()], values: %{term() => String.t()}, omitted: non_neg_integer()}

  @doc """
  Inspects a value with the toolbar limits.

      iex> PhoenixDevToolbar.Truncate.inspect_value(Enum.to_list(1..60)) |> String.ends_with?("...]")
      true

  """
  @spec inspect_value(term(), keyword()) :: String.t()
  def inspect_value(value, opts \\ []), do: inspect(value, Keyword.merge(@inspect_opts, opts))

  @doc """
  Caps a SQL string at #{@sql_limit} bytes.

      iex> PhoenixDevToolbar.Truncate.sql("SELECT 1")
      "SELECT 1"

      iex> PhoenixDevToolbar.Truncate.sql(nil)
      nil

  """
  @spec sql(String.t() | nil) :: String.t() | nil
  def sql(nil), do: nil
  def sql(sql) when is_binary(sql) and byte_size(sql) <= @sql_limit, do: sql
  def sql(sql) when is_binary(sql), do: valid_prefix(sql, @sql_limit) <> " [truncated]"

  @doc """
  Caps any text (exception messages, banners) at `limit` bytes, #{@string_limit} by default.

      iex> PhoenixDevToolbar.Truncate.string("boom")
      "boom"

      iex> "x" |> String.duplicate(3000) |> PhoenixDevToolbar.Truncate.string() |> byte_size()
      2060

  """
  @spec string(String.t(), pos_integer()) :: String.t()
  def string(text, limit \\ @string_limit) when is_binary(text), do: cap(text, limit)

  @doc """
  Formats an exception, throw or exit as a bounded one line banner.
  `Exception.format_banner/2` inspects throw and exit reasons without limits.

      iex> PhoenixDevToolbar.Truncate.banner(:error, %RuntimeError{message: "bad"})
      "** (RuntimeError) bad"

      iex> PhoenixDevToolbar.Truncate.banner(:throw, :oops)
      "** (throw) :oops"

  """
  @spec banner(:error | :exit | :throw, term()) :: String.t()
  def banner(kind, reason) do
    format_banner(kind, reason)
  catch
    # A third party exception's message/1 can itself raise, throw or exit.
    _kind, _reason -> "** (#{inspect_value(error_module(reason))}) <message unavailable>"
  end

  defp format_banner(:error, reason), do: :error |> Exception.format_banner(reason) |> string()
  defp format_banner(kind, reason), do: string("** (#{kind}) " <> inspect_value(reason))

  defp error_module(%{__struct__: module}), do: module
  defp error_module(_reason), do: :error

  @doc """
  Formats the first #{@frames} stacktrace frames that do not belong to the
  toolbar, to `:telemetry` or to the extra `skip` modules and namespaces (an
  Elixir module skips itself and every module nested under it).

      iex> PhoenixDevToolbar.Truncate.stacktrace([{MyApp.Users, :list, 0, [file: ~c"lib/users.ex", line: 3]}])
      ["lib/users.ex:3: MyApp.Users.list/0"]

      iex> PhoenixDevToolbar.Truncate.stacktrace([{Ecto.Repo.Queryable, :all, 3, []}], [Ecto])
      []

      iex> PhoenixDevToolbar.Truncate.stacktrace([{:proc_lib, :init_p, 3, []}], [:proc_lib])
      []

      iex> PhoenixDevToolbar.Truncate.stacktrace(nil)
      []

  """
  @spec stacktrace(Exception.stacktrace() | nil, [module()]) :: [String.t()]
  def stacktrace(frames, skip \\ [])
  def stacktrace(nil, _skip), do: []
  # Ecto passes the `stacktrace: true` option through for raw `query/3`.
  def stacktrace(true, _skip), do: []

  def stacktrace(frames, skip) when is_list(frames) do
    skip = @own_frames ++ skip

    frames
    |> Stream.reject(&skipped_frame?(&1, skip))
    |> Enum.take(@frames)
    |> Enum.map(&Exception.format_stacktrace_entry/1)
  end

  @doc """
  Formats the stacktrace of a crash: like `stacktrace/2`, then cut after the
  last frame of the host's own code plus the one frame that follows (the
  framework frames below it say nothing new), at most #{@frames} frames.

  `apps` is the host's application set (`Collector.host_apps/0`), `app_of` maps
  a module to its application (`:application.get_application/1`, an ETS read:
  fine on the exception path only). With `apps` unknown (`nil`) or no host frame
  in the stacktrace, the first #{@frames} frames are kept.

      iex> frames = [{MyApp.A, :f, 0, []}, {Phoenix.Diff, :g, 0, []}, {MyApp.B, :h, 0, []}, {Phoenix.Diff, :i, 0, []}, {:gen_server, :j, 0, []}]
      iex> app_of = fn module -> if module in [MyApp.A, MyApp.B], do: {:ok, :my_app}, else: :undefined end
      iex> PhoenixDevToolbar.Truncate.exception_stacktrace(frames, [:my_app], app_of)
      ["MyApp.A.f/0", "Phoenix.Diff.g/0", "MyApp.B.h/0", "Phoenix.Diff.i/0"]

  """
  @spec exception_stacktrace(
          Exception.stacktrace() | nil,
          [atom()] | nil,
          (module() -> {:ok, atom()} | :undefined)
        ) :: [String.t()]
  def exception_stacktrace(frames, apps, app_of \\ &:application.get_application/1)
  def exception_stacktrace(nil, _apps, _app_of), do: []

  def exception_stacktrace(frames, apps, app_of) when is_list(frames) do
    frames = Enum.reject(frames, &skipped_frame?(&1, @own_frames))

    frames
    |> cut_after_app(apps, app_of)
    |> Enum.take(@frames)
    |> Enum.map(&Exception.format_stacktrace_entry/1)
  end

  defp cut_after_app(frames, nil, _app_of), do: frames

  defp cut_after_app(frames, apps, app_of) do
    case Enum.find_index(Enum.reverse(frames), &app_frame?(&1, apps, app_of)) do
      nil -> frames
      from_end -> Enum.take(frames, length(frames) - from_end + 1)
    end
  end

  defp app_frame?({module, _fun, _arity, _location}, apps, app_of) when is_atom(module) do
    case app_of.(module) do
      {:ok, app} -> app in apps
      _other -> false
    end
  end

  defp app_frame?(_frame, _apps, _app_of), do: false

  @doc """
  Replaces the value of sensitive keys with `"#{@redacted}"`.

  A key is sensitive when its name (atom or string, case insensitive, the first
  #{@key_prefix} bytes of it) contains one of `keys`. Walks maps, structs,
  keyword lists, lists and tuples, at most #{@list_items} entries per container
  and #{@redact_nodes} nodes in total, so the cost does not depend on the value.

  Contract: a sensitive key's value is `"#{@redacted}"`; anything the walk does
  not reach is replaced by `"#{@cut}"`, never returned as is. The rest of a list
  or tuple becomes a final `"#{@cut}"` element (so does the tail of an improper
  list), the rest of a map becomes a `"#{@cut}" => "#{@cut}"` entry, and a struct
  with more than #{@list_items} fields becomes a plain map with that entry.
  Scalars, including large binaries, are returned as they are (they are cheap;
  `inspect_value/2` bounds their size). Key matching only sees map, struct and
  keyword keys: a bare `{"password", "x"}` tuple outside a list, a charlist key
  and a secret inside a string value are not recognised.

      iex> PhoenixDevToolbar.Truncate.redact(%{"user" => %{"password" => "hunter2", "name" => "Ada"}})
      %{"user" => %{"password" => "[REDACTED]", "name" => "Ada"}}

      iex> PhoenixDevToolbar.Truncate.redact([api_token: "abc", page: 1])
      [api_token: "[REDACTED]", page: 1]

      iex> PhoenixDevToolbar.Truncate.redact({:login, %{password: "hunter2"}})
      {:login, %{password: "[REDACTED]"}}

      iex> PhoenixDevToolbar.Truncate.redact([%{password: "hunter2"} | :tail])
      [%{password: "[REDACTED]"}, "…"]

  """
  @spec redact(term(), [String.t() | atom()]) :: term()
  def redact(value, keys \\ redact_keys()) do
    {redacted, _budget} =
      do_redact(value, Enum.map(keys, &(&1 |> to_string() |> String.downcase())), @redact_nodes)

    redacted
  end

  @doc false
  # Bounded diff of the assigns changed by a callback (LiveView plugin).
  #
  # Lists at most @change_keys of the changed `keys` (sorted; `:all` means every
  # assign) and inspects, redacted, the values of the first @change_values, each
  # capped at @change_bytes bytes. `:flash` is listed without its value.
  # `omitted` counts the keys left out.
  @spec changes(map(), [term()] | :all) :: changes()
  def changes(assigns, :all) when is_map(assigns), do: changes(assigns, Map.keys(assigns))

  def changes(assigns, keys) when is_map(assigns) and is_list(keys) do
    {shown, rest} = keys |> List.delete(:__changed__) |> Enum.sort() |> Enum.split(@change_keys)
    redact = lowered_redact_keys()

    values =
      for key <- Enum.take(shown, @change_values),
          key != :flash,
          is_map_key(assigns, key),
          into: %{},
          do: {key, change_value(key, Map.fetch!(assigns, key), redact)}

    %{keys: shown, values: values, omitted: length(rest)}
  end

  @doc false
  @spec redact_keys() :: [String.t() | atom()]
  def redact_keys do
    configured = Application.get_env(:phoenix_dev_toolbar, :redact, [])
    Enum.uniq(@default_redact ++ List.wrap(configured))
  end

  defp change_value(key, value, redact) do
    case sensitive?(key, redact) do
      true -> inspect_value(@redacted)
      false -> preview(value, @change_bytes, redact)
    end
  end

  @doc false
  # Bounded, redacted view of a whole assigns map for the assigns inspector: at
  # most @snapshot_keys assigns (sorted by key), each through `preview/3`.
  # Runs in the panel's task, never in a host process.
  @spec snapshot(map()) :: %{entries: [{term(), String.t()}], omitted: non_neg_integer()}
  def snapshot(assigns) when is_map(assigns) do
    redact = lowered_redact_keys()

    {shown, rest} =
      assigns
      |> Map.keys()
      |> List.delete(:__changed__)
      |> Enum.sort()
      |> Enum.split(@snapshot_keys)

    entries =
      for key <- shown do
        case sensitive?(key, redact) do
          true -> {key, inspect_value(@redacted)}
          false -> {key, preview(Map.fetch!(assigns, key), @change_bytes, redact)}
        end
      end

    %{entries: entries, omitted: length(rest)}
  end

  @doc """
  Redacted, bounded inspect of any value, at most `bytes` long.

  Unlike `redact/2`, the cost does not depend on the value: at most
  #{@preview_nodes} nodes and #{@preview_width} items per container are walked,
  and whatever is not walked is replaced by `"#{@cut}"`, so a sensitive key
  deep in a large value is cut, never shown.

      iex> PhoenixDevToolbar.Truncate.preview(%{user: %{password: "hunter2"}})
      ~s(%{user: %{password: "[REDACTED]"}})

      iex> PhoenixDevToolbar.Truncate.preview(Enum.to_list(1..30))
      "[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, ...]"

  """
  @spec preview(term(), pos_integer(), [String.t()]) :: String.t()
  def preview(value, bytes \\ @change_bytes, redact \\ lowered_redact_keys()) do
    {pruned, _budget} = prune(value, @preview_nodes, redact)
    pruned |> inspect_value(@change_inspect) |> string(bytes)
  end

  defp lowered_redact_keys, do: Enum.map(redact_keys(), &(&1 |> to_string() |> String.downcase()))

  defp prune(_value, budget, _keys) when budget <= 0, do: {@cut, 0}

  # Structs made of scalars only (dates, decimals) keep their own Inspect, unless
  # a field name is sensitive.
  defp prune(%{__struct__: _} = struct, budget, keys) do
    case Enum.any?(Map.to_list(struct), &walk_field?(&1, keys)) do
      true -> prune_fields(struct, budget - 1, keys)
      false -> {struct, budget - 1}
    end
  end

  defp prune(%{} = map, budget, keys) do
    {pairs, budget} =
      map
      |> first_entries(@preview_width)
      |> Enum.map_reduce(budget - 1, &prune_pair(&1, &2, keys))

    pruned = Map.new(pairs)

    case map_size(map) > @preview_width do
      true -> {Map.put(pruned, @cut, @cut), budget}
      false -> {pruned, budget}
    end
  end

  defp prune(list, budget, keys) when is_list(list) do
    case proper_split(list, @preview_width) do
      {:ok, head, rest} ->
        {items, budget} = Enum.map_reduce(head, budget - 1, &prune_item(&1, &2, keys))
        {items ++ cut_marker(rest), budget}

      :improper ->
        {@cut, budget - 1}
    end
  end

  defp prune(tuple, budget, keys) when is_tuple(tuple) do
    shown = min(tuple_size(tuple), @preview_width)
    head = for index <- 0..(shown - 1)//1, do: elem(tuple, index)
    {items, budget} = Enum.map_reduce(head, budget - 1, &prune_item(&1, &2, keys))
    {List.to_tuple(items ++ cut_marker(tuple_size(tuple) > shown)), budget}
  end

  defp prune(value, budget, _keys), do: {value, budget - 1}

  # A struct keeps every field (derived Inspect implementations expect them):
  # fields past the budget become "…".
  defp prune_fields(struct, budget, keys) do
    struct
    |> Map.from_struct()
    |> Enum.reduce({struct, budget}, fn {key, value}, {acc, left} ->
      {{_key, pruned}, left} = prune_pair({key, value}, left, keys)
      {Map.put(acc, key, pruned), left}
    end)
  end

  defp prune_pair({key, value}, budget, keys) do
    case sensitive?(key, keys) do
      true ->
        {{key, @redacted}, budget - 1}

      false ->
        {pruned, budget} = prune(value, budget, keys)
        {{key, pruned}, budget}
    end
  end

  defp prune_item({key, _value} = pair, budget, keys) when is_atom(key) or is_binary(key),
    do: prune_pair(pair, budget, keys)

  defp prune_item(item, budget, keys), do: prune(item, budget, keys)

  defp cut_marker(rest) when rest in [[], false], do: []
  defp cut_marker(_rest), do: [@cut]

  defp walk_field?({key, value}, keys), do: container?(value) or sensitive?(key, keys)

  defp container?(value) when is_map(value) or is_list(value) or is_tuple(value), do: true
  defp container?(_value), do: false

  defp cap(text, limit) when byte_size(text) <= limit, do: text
  defp cap(text, limit), do: valid_prefix(text, limit) <> " [truncated]"

  # Nothing unvisited is returned as is: what the walk does not reach is @cut.
  defp do_redact(_value, _keys, budget) when budget <= 0, do: {@cut, 0}

  # Maps and structs: only the first @list_items entries (iteration order) are
  # walked and kept, the rest becomes a "…" entry. A struct with more fields
  # than that is a plain map afterwards (its Inspect would expect every field).
  defp do_redact(%{} = map, keys, budget) do
    {pairs, budget} =
      map
      |> first_entries(@list_items + 1)
      |> Enum.reject(fn {key, _value} -> key == :__struct__ end)
      |> Enum.take(@list_items)
      |> Enum.map_reduce(budget - 1, fn {key, value}, left ->
        {value, left} = redact_pair(key, value, keys, left)
        {{key, value}, left}
      end)

    {rebuild(map, pairs), budget}
  end

  defp do_redact(list, keys, budget) when is_list(list) do
    {head, cut?} = redact_split(list, @list_items, [])
    {items, budget} = Enum.map_reduce(head, budget - 1, &redact_item(&1, keys, &2))
    {items ++ cut_marker(cut?), budget}
  end

  # Tuples (messages, {:ok, value} results): the first @list_items elements.
  defp do_redact(tuple, keys, budget) when is_tuple(tuple) do
    shown = min(tuple_size(tuple), @list_items)
    head = for index <- 0..(shown - 1)//1, do: elem(tuple, index)
    {items, budget} = Enum.map_reduce(head, budget - 1, &do_redact(&1, keys, &2))
    {List.to_tuple(items ++ cut_marker(tuple_size(tuple) > shown)), budget}
  end

  defp do_redact(value, _keys, budget), do: {value, budget - 1}

  defp rebuild(map, pairs) do
    cut? = map_size(map) - struct_key(map) > length(pairs)
    walked = Map.new(pairs)

    case {cut?, map} do
      {true, _map} -> Map.put(walked, @cut, @cut)
      {false, %{__struct__: _}} -> Map.merge(map, walked)
      {false, _map} -> walked
    end
  end

  defp struct_key(%{__struct__: _}), do: 1
  defp struct_key(_map), do: 0

  # Splits off the first `n` items of a list; the flag says whether anything
  # (items or an improper tail) was left out.
  defp redact_split([], _n, acc), do: {Enum.reverse(acc), false}
  defp redact_split([item | rest], n, acc) when n > 0, do: redact_split(rest, n - 1, [item | acc])
  defp redact_split(_rest, _n, acc), do: {Enum.reverse(acc), true}

  defp first_entries(map, n), do: map |> :maps.iterator() |> take_entries(n, [])

  defp take_entries(_iterator, 0, acc), do: acc

  defp take_entries(iterator, n, acc) do
    case :maps.next(iterator) do
      {key, value, next} -> take_entries(next, n - 1, [{key, value} | acc])
      :none -> acc
    end
  end

  defp redact_item({key, value}, keys, budget) when is_atom(key) or is_binary(key) do
    {value, budget} = redact_pair(key, value, keys, budget)
    {{key, value}, budget}
  end

  defp redact_item(value, keys, budget), do: do_redact(value, keys, budget)

  defp redact_pair(key, value, keys, budget) do
    case sensitive?(key, keys) do
      true -> {@redacted, budget - 1}
      false -> do_redact(value, keys, budget)
    end
  end

  defp sensitive?(key, keys) when is_atom(key) or is_binary(key) do
    name = key |> key_prefix() |> String.downcase()
    Enum.any?(keys, &String.contains?(name, &1))
  end

  defp sensitive?(_key, _keys), do: false

  # Atoms are at most 255 characters; a binary key can be any size.
  defp key_prefix(key) when is_atom(key), do: Atom.to_string(key)
  defp key_prefix(key) when byte_size(key) <= @key_prefix, do: key
  defp key_prefix(key), do: valid_prefix(key, @key_prefix)

  # Splits a list into its first `n` items and the rest, refusing improper lists.
  defp proper_split(list, n), do: proper_split(list, n, [])

  defp proper_split([], _n, acc), do: {:ok, Enum.reverse(acc), []}
  defp proper_split([_ | _] = rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}
  defp proper_split([item | rest], n, acc), do: proper_split(rest, n - 1, [item | acc])
  defp proper_split(_improper, _n, _acc), do: :improper

  defp skipped_frame?({module, _fun, _arity, _location}, skip) when is_atom(module) do
    name = Atom.to_string(module)
    Enum.any?(skip, &(module == &1 or String.starts_with?(name, Atom.to_string(&1) <> ".")))
  end

  defp skipped_frame?(_frame, _skip), do: false

  # Cuts at `limit` bytes without splitting a UTF-8 codepoint (at most 3 bytes
  # back). Binaries that are not UTF-8 at all are cut at `limit`.
  defp valid_prefix(binary, limit), do: valid_prefix(binary, limit, 0)

  defp valid_prefix(binary, limit, back) when back > 3, do: binary_part(binary, 0, limit)

  defp valid_prefix(binary, limit, back) do
    prefix = binary_part(binary, 0, limit - back)

    case String.valid?(prefix) do
      true -> prefix
      false -> valid_prefix(binary, limit, back + 1)
    end
  end
end
