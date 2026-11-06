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

  # ecto_sql is optional: run/2 is only reached for an attached Ecto plugin.
  @compile {:no_warn_undefined, Ecto.Adapters.SQL}

  @max_params 50
  @max_bytes 4096
  @timeout 5_000
  @plan_bytes 8192

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Truncate

  @type error ::
          :not_query
          | :repo_not_configured
          | :not_explainable
          | :query_failed
          | :not_select
          | :multiple_statements
          | :escapes
          | :unsupported_adapter

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
  Explains a captured query, in the calling process (the Ecto tab runs it in
  `start_async/3`). The event must be an Ecto query of one of `repos`, with
  captured params; its SQL is checked again: a single SELECT statement.

  The prefix depends on the adapter (`EXPLAIN` for Postgres and MyXQL,
  `EXPLAIN QUERY PLAN` for SQLite3; never `ANALYZE`, which runs the query). It
  runs in a transaction that is always rolled back, with a #{@timeout} ms
  timeout (and `statement_timeout` on Postgres). The plan is truncated.
  """
  @spec run(Event.t(), [module()]) :: {:ok, String.t()} | {:error, error() | String.t()}
  def run(%Event{plugin: :ecto, kind: :query, data: data}, repos) do
    with {:ok, repo} <- configured(data[:repo], repos),
         :ok <- succeeded(data[:result]),
         {:ok, params} <- explainable(data[:explain]),
         :ok <- single_select(data[:sql]),
         {:ok, prefix} <- prefix(repo) do
      explain(repo, prefix <> data.sql, params)
    end
  end

  def run(_event, _repos), do: {:error, :not_query}

  @doc "Why a query cannot be explained, for the Ecto tab."
  @spec reason(error() | String.t()) :: String.t()
  def reason(:not_query), do: "not a query"
  def reason(:repo_not_configured), do: "its repo is not configured"
  def reason(:not_explainable), do: "its params could not be kept"
  def reason(:query_failed), do: "the query itself failed"
  def reason(:not_select), do: "only SELECT queries are explained"
  def reason(:multiple_statements), do: "only single statements are explained"
  def reason(:escapes), do: "its SQL has backslash escapes, which differ between databases"
  def reason(:unsupported_adapter), do: "this database adapter is not supported"
  def reason(message) when is_binary(message), do: message

  @doc "Whether the adapter of `repo` has an EXPLAIN prefix."
  @spec supported?(module()) :: boolean()
  def supported?(repo), do: match?({:ok, _prefix}, prefix(repo))

  defp configured(repo, repos) when is_atom(repo) and repo != nil do
    case repo in repos do
      true -> {:ok, repo}
      false -> {:error, :repo_not_configured}
    end
  end

  defp configured(_repo, _repos), do: {:error, :repo_not_configured}

  # The database parsed the stored SQL as the query it ran: with the prefix it
  # can only be EXPLAIN of that query. A failed one could be anything (a
  # comment trick that turns the prefix into EXPLAIN ANALYZE).
  defp succeeded({:ok, _rows}), do: :ok
  defp succeeded(_result), do: {:error, :query_failed}

  defp explainable({:ok, params}) when is_list(params), do: {:ok, params}
  defp explainable(_capture), do: {:error, :not_explainable}

  defp single_select(sql) when is_binary(sql) do
    cond do
      not select?(sql) -> {:error, :not_select}
      # A backslash escapes a quote in MySQL strings, not in Postgres ones: the
      # separator scan cannot be sure, so such SQL is not explained.
      String.contains?(sql, "\\") -> {:error, :escapes}
      separator?(sql) -> {:error, :multiple_statements}
      # MySQL runs the text of a versioned comment (/*!80018 ... */).
      String.contains?(sql, "/*!") -> {:error, :not_select}
      true -> :ok
    end
  end

  defp single_select(_sql), do: {:error, :not_select}

  # A `;` outside quotes and comments: SQL is at most 8 KB (stored whole).
  defp separator?(<<"'", rest::binary>>), do: rest |> after_quote(?') |> separator?()
  defp separator?(<<"\"", rest::binary>>), do: rest |> after_quote(?") |> separator?()
  defp separator?("--" <> rest), do: rest |> after_line() |> separator?()
  defp separator?("/*" <> rest), do: rest |> after_block() |> separator?()
  defp separator?(";" <> rest), do: String.trim(rest) != ""
  defp separator?(<<_c, rest::binary>>), do: separator?(rest)
  defp separator?(<<>>), do: false

  # Doubled quotes ('it''s') close and reopen: both halves are skipped alike.
  defp after_quote(sql, quote) do
    case :binary.split(sql, <<quote>>) do
      [_quoted, rest] -> rest
      [_unterminated] -> ""
    end
  end

  defp prefix(repo) do
    case Code.ensure_loaded?(repo) and function_exported?(repo, :__adapter__, 0) and
           repo.__adapter__() do
      Ecto.Adapters.Postgres -> {:ok, "EXPLAIN "}
      Ecto.Adapters.MyXQL -> {:ok, "EXPLAIN "}
      Ecto.Adapters.SQLite3 -> {:ok, "EXPLAIN QUERY PLAN "}
      _other -> {:error, :unsupported_adapter}
    end
  end

  defp explain(repo, sql, params) do
    result =
      repo.transaction(
        fn ->
          _ = postgres?(repo) && repo.query!("SET LOCAL statement_timeout = #{@timeout}")
          repo.rollback(query(repo, sql, params))
        end,
        timeout: @timeout
      )

    case result do
      {:error, {:ok, plan}} -> {:ok, plan}
      {:error, {:error, message}} -> {:error, message}
      {:error, other} -> {:error, Truncate.inspect_value(other)}
    end
  rescue
    exception -> {:error, exception |> Exception.message() |> Truncate.string()}
  catch
    kind, reason -> {:error, Truncate.banner(kind, reason)}
  end

  defp postgres?(repo), do: repo.__adapter__() == Ecto.Adapters.Postgres

  defp query(repo, sql, params) do
    case repo.query(sql, params, timeout: @timeout) do
      {:ok, result} -> {:ok, result |> format() |> Truncate.string(@plan_bytes)}
      {:error, error} -> {:error, error |> Exception.message() |> Truncate.string()}
    end
  end

  # Postgres answers one "QUERY PLAN" line per row: shown as text.
  defp format(%{rows: rows}) when rows in [nil, []], do: "(no plan rows)"
  defp format(%{columns: ["QUERY PLAN"], rows: rows}), do: Enum.map_join(rows, "\n", &Enum.join/1)
  defp format(result), do: Ecto.Adapters.SQL.format_table(result)

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

  # A big integer (or a Decimal's coefficient) counts its bytes.
  defp param(param, budget) when is_integer(param), do: integer(param, budget)
  # Matched by name: `decimal` is not a dependency (a %Decimal{} pattern would
  # not compile in a host without it).
  defp param(%{__struct__: Decimal, coef: coef}, budget) when is_integer(coef),
    do: integer(coef, budget)

  defp param(param, {count, bytes}) when is_float(param) or is_boolean(param) or is_nil(param),
    do: {:ok, {count + 1, bytes}}

  defp param(%module{}, {count, bytes}) when module in @scalar_structs,
    do: {:ok, {count + 1, bytes}}

  defp param(_other, _budget), do: :error

  defp integer(int, {count, bytes}) when int > -0x8000000000000000 and int < 0x8000000000000000,
    do: {:ok, {count + 1, bytes}}

  defp integer(int, {count, bytes}) do
    case bytes + byte_size(:binary.encode_unsigned(abs(int))) do
      total when total <= @max_bytes -> {:ok, {count + 1, total}}
      _over -> :error
    end
  end

  defp copy(binary) when is_binary(binary), do: :binary.copy(binary)
  defp copy(list) when is_list(list), do: Enum.map(list, &copy/1)
  defp copy(param), do: param
end
