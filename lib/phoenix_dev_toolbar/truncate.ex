defmodule PhoenixDevToolbar.Truncate do
  @moduledoc false
  # Bounds every payload before it is stored (ADR 03). Runs inside host
  # processes, so every function is pure and cheap on small inputs and bounded
  # on large ones.

  @inspect_opts [limit: 50, printable_limit: 1024]
  @sql_limit 8192
  @string_limit 2048
  @frames 10
  @redacted "[REDACTED]"
  # Containers deeper than this, or list items past @list_items, are left as is:
  # the inspect limits hide them anyway.
  @max_depth 6
  @list_items 50
  @default_redact ["password", "token", "secret"]
  @own_frames [:telemetry, PhoenixDevToolbar]
  # Assigns diff of one callback (ADR 03): about 4 KB at most.
  @change_keys 20
  @change_values 10
  @change_inspect [limit: 20, printable_limit: 256]
  @change_bytes 360
  # A preview walks at most @preview_nodes nodes and @preview_width items per
  # container, whatever the value's size: assigns can be huge (ADR 03).
  @preview_nodes 200
  @preview_width 20
  @cut "…"

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
  def banner(:error, reason), do: :error |> Exception.format_banner(reason) |> string()
  def banner(kind, reason), do: string("** (#{kind}) " <> inspect_value(reason))

  @doc """
  Formats the first #{@frames} stacktrace frames that do not belong to the
  toolbar, to `:telemetry` or to the extra `skip` modules and namespaces (an
  Elixir module skips itself and every module nested under it).

      iex> PhoenixDevToolbar.Truncate.stacktrace([{MyApp.Users, :list, 0, [file: ~c"lib/users.ex", line: 3]}])
      ["lib/users.ex:3: MyApp.Users.list/0"]

      iex> PhoenixDevToolbar.Truncate.stacktrace([{Ecto.Repo.Queryable, :all, 3, []}], [Ecto])
      []

      iex> PhoenixDevToolbar.Truncate.stacktrace(nil)
      []

  """
  @spec stacktrace(Exception.stacktrace() | nil, [module()]) :: [String.t()]
  def stacktrace(frames, skip \\ [])
  def stacktrace(nil, _skip), do: []

  def stacktrace(frames, skip) when is_list(frames) do
    skip = @own_frames ++ skip

    frames
    |> Stream.reject(&skipped_frame?(&1, skip))
    |> Enum.take(@frames)
    |> Enum.map(&Exception.format_stacktrace_entry/1)
  end

  @doc """
  Replaces the value of sensitive keys with `"#{@redacted}"`.

  A key is sensitive when its name (atom or string, case insensitive) contains
  one of `keys`. Walks maps, structs, keyword lists and lists, bounded in depth
  and length.

      iex> PhoenixDevToolbar.Truncate.redact(%{"user" => %{"password" => "hunter2", "name" => "Ada"}})
      %{"user" => %{"password" => "[REDACTED]", "name" => "Ada"}}

      iex> PhoenixDevToolbar.Truncate.redact([api_token: "abc", page: 1])
      [api_token: "[REDACTED]", page: 1]

  """
  @spec redact(term(), [String.t() | atom()]) :: term()
  def redact(value, keys \\ redact_keys()) do
    do_redact(value, Enum.map(keys, &(&1 |> to_string() |> String.downcase())), 0)
  end

  @doc """
  Bounded diff of the assigns changed by a callback.

  Lists at most #{@change_keys} of the changed `keys` (sorted; `:all` means every
  assign) and inspects, redacted, the values of the first #{@change_values}, each
  capped at #{@change_bytes} bytes. `:flash` is listed without its value.
  `omitted` counts the keys left out.

      iex> PhoenixDevToolbar.Truncate.changes(%{count: 2, password: "x"}, [:count, :password])
      %{keys: [:count, :password], values: %{count: "2", password: ~s("[REDACTED]")}, omitted: 0}

  """
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
  def redact_keys, do: Application.get_env(:phoenix_dev_toolbar, :redact, @default_redact)

  defp change_value(key, value, redact) do
    case sensitive?(key, redact) do
      true -> inspect_value(@redacted)
      false -> preview(value, @change_bytes, redact)
    end
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

  # Structs made of scalars only (dates, decimals) keep their own Inspect.
  defp prune(%{__struct__: _} = struct, budget, keys) do
    case Enum.any?(Map.values(struct), &container?/1) do
      false -> {struct, budget - 1}
      true -> prune_fields(struct, budget - 1, keys)
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

  defp container?(value) when is_map(value) or is_list(value) or is_tuple(value), do: true
  defp container?(_value), do: false

  defp cap(text, limit) when byte_size(text) <= limit, do: text
  defp cap(text, limit), do: valid_prefix(text, limit) <> " [truncated]"

  defp do_redact(value, _keys, depth) when depth > @max_depth, do: value

  # Maps and structs: only the first @list_items entries (iteration order) are
  # walked and written back, so cost does not grow with the map size. The rest
  # is left to the inspect limit, which shows at most 50 entries.
  defp do_redact(%{} = map, keys, depth) do
    redacted =
      for {key, value} <- first_entries(map, @list_items),
          key != :__struct__,
          into: %{},
          do: {key, redact_pair(key, value, keys, depth)}

    Map.merge(map, redacted)
  end

  defp do_redact(list, keys, depth) when is_list(list) do
    case proper_split(list, @list_items) do
      {:ok, head, rest} -> Enum.map(head, &redact_item(&1, keys, depth)) ++ rest
      :improper -> list
    end
  end

  defp do_redact(value, _keys, _depth), do: value

  defp first_entries(map, n), do: map |> :maps.iterator() |> take_entries(n, [])

  defp take_entries(_iterator, 0, acc), do: acc

  defp take_entries(iterator, n, acc) do
    case :maps.next(iterator) do
      {key, value, next} -> take_entries(next, n - 1, [{key, value} | acc])
      :none -> acc
    end
  end

  defp redact_item({key, value}, keys, depth) when is_atom(key) or is_binary(key),
    do: {key, redact_pair(key, value, keys, depth)}

  defp redact_item(value, keys, depth), do: do_redact(value, keys, depth + 1)

  defp redact_pair(key, value, keys, depth) do
    case sensitive?(key, keys) do
      true -> @redacted
      false -> do_redact(value, keys, depth + 1)
    end
  end

  defp sensitive?(key, keys) when is_atom(key) or is_binary(key) do
    name = key |> to_string() |> String.downcase()
    Enum.any?(keys, &String.contains?(name, &1))
  end

  defp sensitive?(_key, _keys), do: false

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
