defmodule PhoenixDevToolbar.Truncate do
  @moduledoc false
  # Bounds every payload before it is stored (ADR 03). Runs inside host
  # processes, so every function is pure and cheap on small inputs and bounded
  # on large ones.

  @inspect_opts [limit: 50, printable_limit: 1024]
  @sql_limit 8192
  @frames 10
  @redacted "[REDACTED]"
  # Containers deeper than this, or list items past @list_items, are left as is:
  # the inspect limits hide them anyway.
  @max_depth 6
  @list_items 50
  @default_redact ["password", "token", "secret"]
  @own_frames [:telemetry, PhoenixDevToolbar]

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
  Formats the first #{@frames} stacktrace frames that do not belong to the
  toolbar or to `:telemetry`.

      iex> PhoenixDevToolbar.Truncate.stacktrace([{MyApp.Users, :list, 0, [file: ~c"lib/users.ex", line: 3]}])
      ["lib/users.ex:3: MyApp.Users.list/0"]

      iex> PhoenixDevToolbar.Truncate.stacktrace(nil)
      []

  """
  @spec stacktrace(Exception.stacktrace() | nil) :: [String.t()]
  def stacktrace(nil), do: []

  def stacktrace(frames) when is_list(frames) do
    frames
    |> Stream.reject(&own_frame?/1)
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

  @doc false
  @spec redact_keys() :: [String.t() | atom()]
  def redact_keys, do: Application.get_env(:phoenix_dev_toolbar, :redact, @default_redact)

  defp do_redact(value, _keys, depth) when depth > @max_depth, do: value

  defp do_redact(%{__struct__: _} = struct, keys, depth) do
    struct
    |> Map.from_struct()
    |> Enum.reduce(struct, fn {key, value}, acc ->
      Map.put(acc, key, redact_pair(key, value, keys, depth))
    end)
  end

  defp do_redact(%{} = map, keys, depth) do
    Map.new(map, fn {key, value} -> {key, redact_pair(key, value, keys, depth)} end)
  end

  defp do_redact(list, keys, depth) when is_list(list) do
    case proper_split(list, @list_items) do
      {:ok, head, rest} -> Enum.map(head, &redact_item(&1, keys, depth)) ++ rest
      :improper -> list
    end
  end

  defp do_redact(value, _keys, _depth), do: value

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

  defp own_frame?({module, _fun, _arity, _location}) when is_atom(module) do
    Enum.any?(@own_frames, fn
      :telemetry -> module == :telemetry
      prefix -> module == prefix or String.starts_with?(Atom.to_string(module), "#{prefix}.")
    end)
  end

  defp own_frame?(_frame), do: false

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
