defmodule PhoenixDevToolbar.Explain do
  @moduledoc false
  # EXPLAIN for captured queries (ADR 08).
  #
  # `capture/2` runs in the host process, inside the Ecto plugin's collect/3:
  # it keeps the raw params a SELECT needs to be explained later, only when
  # they are few, small scalars (the walk is bounded by those limits). They are
  # stored in the event and never rendered: params stay redacted on screen, the
  # raw ones only go back to the database.

  @max_params 50
  @max_bytes 4096

  @type capture :: {:ok, [term()]} | {:no, :not_select | :sql_truncated | :params}

  @scalar_structs [Date, Time, NaiveDateTime, DateTime, Decimal]

  @doc """
  What EXPLAIN needs from a query: its params, when the SQL is a SELECT stored
  whole (`stored`, from `PhoenixDevToolbar.Truncate.sql/1`, is the raw `sql`)
  and the params are at most #{@max_params} scalars of #{@max_bytes} bytes in all.
  """
  @spec capture(term(), String.t() | nil, term()) :: capture()
  def capture(sql, stored, params) when is_binary(sql) do
    cond do
      not select?(sql) -> {:no, :not_select}
      stored != sql -> {:no, :sql_truncated}
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
    case walk(params, {0, 0}) do
      {:ok, _budget} -> {:ok, params}
      :error -> {:no, :params}
    end
  end

  defp capture_params(_params), do: {:no, :params}

  # Arrays (lists) of scalars count each element against the budget.
  defp walk([], budget), do: {:ok, budget}

  defp walk([param | rest], budget) do
    with {:ok, budget} <- param(param, budget), do: walk(rest, budget)
  end

  defp walk(_improper, _budget), do: :error

  defp param(_param, {count, _bytes}) when count >= @max_params, do: :error

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

  defp param(list, budget) when is_list(list), do: walk(list, budget)
  defp param(_other, _budget), do: :error
end
