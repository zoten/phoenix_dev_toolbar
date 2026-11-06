defmodule PhoenixDevToolbar.Explain do
  @moduledoc false
  # EXPLAIN for captured queries (ADR 08).
  #
  # `capture/3` runs in the host process, inside the Ecto plugin's collect/3:
  # it keeps the raw params a SELECT needs to be explained later, only when
  # they are few, small scalars (the walk is bounded by those limits). They are
  # stored in the event and never rendered: params stay redacted on screen, the
  # raw ones only go back to the database. Binaries are copied, so a param cut
  # out of a large body (a sub-binary) does not keep the body alive.
  #
  # Not replayable, so not captured: maps (json params), tuples, and structs
  # other than the scalar ones below. Arrays are one level of scalars.

  @max_params 50
  @max_bytes 4096

  @type capture :: {:ok, [term()]} | {:no, :not_select | :sql_truncated | :params}

  @scalar_structs [
    Date,
    Time,
    NaiveDateTime,
    DateTime,
    Decimal,
    Duration,
    Postgrex.Interval,
    Postgrex.INET
  ]

  @doc """
  What EXPLAIN needs from a query: its params, when the SQL is a SELECT stored
  whole (`stored`, from `PhoenixDevToolbar.Truncate.sql/1`, is the raw `sql`)
  and the params are at most #{@max_params} scalars of #{@max_bytes} bytes in all.
  """
  @spec capture(term(), String.t() | nil, term()) :: capture()
  def capture(sql, stored, params) when is_binary(sql) do
    # The length check first: it bounds the comment walk of select?/1.
    cond do
      stored != sql -> {:no, :sql_truncated}
      not select?(sql) -> {:no, :not_select}
      true -> capture_params(params)
    end
  end

  def capture(_sql, _stored, _params), do: {:no, :not_select}

  @doc """
  Whether `sql` starts with `SELECT` or `WITH`, after whitespace and comments.

      iex> PhoenixDevToolbar.Explain.select?("  -- users\\n/* list */ select 1")
      true

      iex> PhoenixDevToolbar.Explain.select?("UPDATE users SET name = $1")
      false

  """
  @spec select?(String.t()) :: boolean()
  def select?(sql) when is_binary(sql) do
    case sql |> statement() |> first_word() do
      word when word in ["select", "with"] -> true
      _other -> false
    end
  end

  defp statement(<<c, rest::binary>>) when c in [?\s, ?\t, ?\r, ?\n], do: statement(rest)
  defp statement("--" <> rest), do: rest |> after_line() |> statement()
  defp statement("/*" <> rest), do: rest |> after_block() |> statement()
  defp statement(sql), do: sql

  defp after_line(sql) do
    case :binary.split(sql, "\n") do
      [_comment, rest] -> rest
      [_comment] -> ""
    end
  end

  defp after_block(sql) do
    case :binary.split(sql, "*/") do
      [_comment, rest] -> rest
      [_comment] -> ""
    end
  end

  # The leading keyword, lowercased: at most 7 bytes are looked at.
  defp first_word(sql) do
    head = binary_part(sql, 0, min(byte_size(sql), 7))

    case :binary.split(head, [" ", "\t", "\r", "\n", "("]) do
      [word | _rest] -> String.downcase(word)
    end
  end

  defp capture_params(params) when is_list(params) do
    case walk(params, {0, 0}, :top) do
      {:ok, _budget} -> {:ok, Enum.map(params, &copy/1)}
      :error -> {:no, :params}
    end
  end

  defp capture_params(_params), do: {:no, :params}

  # Every param, array and array element counts against the budget; arrays
  # hold scalars only (one level), so the walk is bounded by the budget.
  defp walk([], budget, _level), do: {:ok, budget}

  defp walk([param | rest], budget, level) do
    with {:ok, budget} <- param(param, budget, level), do: walk(rest, budget, level)
  end

  defp walk(_improper, _budget, _level), do: :error

  defp param(_param, {count, _bytes}, _level) when count >= @max_params, do: :error

  defp param(list, {count, bytes}, :top) when is_list(list),
    do: walk(list, {count + 1, bytes}, :array)

  defp param(list, _budget, :array) when is_list(list), do: :error
  defp param(param, budget, _level), do: param(param, budget)

  defp param(param, {count, bytes}) when is_binary(param) do
    case bytes + byte_size(param) do
      total when total <= @max_bytes -> {:ok, {count + 1, total}}
      _over -> :error
    end
  end

  defp param(param, {count, bytes})
       when is_integer(param) or is_float(param) or is_boolean(param) or is_nil(param),
       do: {:ok, {count + 1, bytes}}

  defp param(%module{}, {count, bytes}) when module in @scalar_structs,
    do: {:ok, {count + 1, bytes}}

  defp param(_other, _budget), do: :error

  defp copy(binary) when is_binary(binary), do: :binary.copy(binary)
  defp copy(list) when is_list(list), do: Enum.map(list, &copy/1)
  defp copy(param), do: param
end
