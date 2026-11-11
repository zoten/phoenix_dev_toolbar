defmodule PhoenixDevToolbar.Report.Markdown do
  @moduledoc false
  # Renders a `Report.summary/2` (verbose, so the slowest queries carry their
  # SQL) as Markdown for an agent or a bug report (ADR 13). Pure string
  # building: every list is already capped by the summary, every table cell is
  # escaped, SQL that is long or multi-line goes in a fenced block under its
  # table, so a table row is always one line.

  @inline_sql 80
  @cell_max 300

  @doc "The Markdown for a `Report.summary/2` built with `verbose: true`."
  @spec render(PhoenixDevToolbar.Report.summary()) :: String.t()
  def render(summary) do
    [
      heading(summary),
      request(summary.request),
      totals(summary),
      n_plus_one(summary.n_plus_one),
      slowest_queries(summary.queries.slowest),
      slowest_callbacks(summary.callbacks.slowest),
      unattributed(summary.unattributed),
      errors(summary.errors),
      lost(summary)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp heading(%{session: session}) do
    view = if session.view, do: " (`#{inspect(session.view)}`)"
    "# #{cell(session.path || "unknown path")}#{view}"
  end

  defp request(nil), do: nil

  defp request(request) do
    parts = [
      request.method,
      request.status && "status #{request.status}",
      ms(request.duration_us)
    ]

    "Request: " <> (parts |> Enum.reject(&is_nil/1) |> Enum.join(", "))
  end

  defp totals(summary) do
    queries = summary.queries
    failed = if queries.failed > 0, do: " (#{queries.failed} failed)"

    """
    ## Queries

    #{queries.count} queries#{failed}, #{ms(queries.total_us) || "0 ms"}. \
    Callbacks: #{summary.callbacks.count}, #{ms(summary.callbacks.total_us) || "0 ms"}. \
    Renders: #{summary.renders.count}.\
    """
  end

  defp n_plus_one([]), do: nil

  defp n_plus_one(groups) do
    sql_table(
      "## N+1",
      "N",
      ["SQL", "Origin", "Count"],
      for g <- groups do
        {g.sql, [cell(g.origin), g.count]}
      end
    )
  end

  defp slowest_queries([]), do: nil

  defp slowest_queries(queries) do
    sql_table(
      "## Slowest queries",
      "Q",
      ["SQL", "Time", "Rows", "Origin"],
      for q <- queries do
        {q.sql, [ms(q.duration_us), q.rows, cell(q.origin)]}
      end
    )
  end

  defp slowest_callbacks([]), do: nil

  defp slowest_callbacks(callbacks) do
    rows =
      for c <- callbacks do
        [
          cell(callback_name(c)),
          ms(c.duration_us),
          c.queries,
          cell(c.origin)
        ]
      end

    table("## Slowest callbacks", ["Callback", "Time", "Queries", "Origin"], rows)
  end

  defp callback_name(c) do
    owner = c.component || c.view
    event = if c.event, do: " #{c.event}"
    inferred = if c.inferred, do: " (inferred)"
    "#{if owner, do: inspect(owner) <> " "}#{c.callback}#{event}#{inferred}"
  end

  defp unattributed(%{count: 0}), do: nil

  defp unattributed(%{origins: origins} = un) do
    rows = for o <- origins, do: [cell(o.origin), o.count, ms(o.total_us)]

    table(
      "## Unattributed queries\n\n#{un.count} queries in no callback (usually handle_info or PubSub).",
      ["Origin", "Count", "Time"],
      rows
    )
  end

  defp errors([]), do: nil

  defp errors(errors) do
    table(
      "## Errors",
      ["Source", "Message", "Origin"],
      for e <- errors do
        [cell(e.source), cell(e.message), cell(e.origin)]
      end
    )
  end

  defp lost(%{dropped: 0, trimmed: 0}), do: nil

  defp lost(%{dropped: dropped, trimmed: trimmed}) do
    "Incomplete: #{dropped} events dropped, #{trimmed} trimmed."
  end

  ## Tables

  defp table(title, headers, rows) do
    [title, "", row(headers), row(Enum.map(headers, fn _ -> "---" end)) | Enum.map(rows, &row/1)]
    |> Enum.join("\n")
  end

  # Rows whose SQL is long or multi-line show a reference (Q1) in the cell and
  # the SQL in a fenced block under the table.
  defp sql_table(title, prefix, headers, items) do
    numbered = Enum.with_index(items, 1)

    rows =
      for {{sql, rest}, i} <- numbered do
        [sql_cell(sql, "#{prefix}#{i}") | rest]
      end

    blocks =
      for {{sql, _rest}, i} <- numbered, fenced?(sql) do
        "#{prefix}#{i}:\n" <> fence(sql)
      end

    Enum.join([table(title, headers, rows) | blocks], "\n\n")
  end

  defp sql_cell(nil, _ref), do: "-"
  defp sql_cell(sql, ref), do: if(fenced?(sql), do: "see #{ref}", else: cell(sql))

  defp fenced?(nil), do: false

  defp fenced?(sql), do: String.contains?(sql, "\n") or String.length(sql) > @inline_sql

  defp fence(sql) do
    ticks = String.duplicate("`", max(3, longest_run(sql) + 1))
    "#{ticks}sql\n#{sql}\n#{ticks}"
  end

  defp longest_run(text) do
    ~r/`+/
    |> Regex.scan(text)
    |> Enum.map(fn [run] -> String.length(run) end)
    |> Enum.max(fn -> 0 end)
  end

  defp row(cells), do: "| " <> Enum.map_join(cells, " | ", &to_cell/1) <> " |"

  defp to_cell(nil), do: "-"
  defp to_cell(value) when is_binary(value), do: value
  defp to_cell(value), do: to_string(value)

  # One line, no table or code syntax.
  defp cell(nil), do: nil

  defp cell(value) do
    value
    |> to_string()
    |> String.replace(~r/\s*[\r\n]+\s*/, " ")
    |> String.replace("|", "\\|")
    |> String.replace("`", "\\`")
    |> String.slice(0, @cell_max)
  end

  defp ms(nil), do: nil
  defp ms(us), do: "#{Float.round(us / 1000, 1)} ms"
end
