defmodule PhoenixDevToolbar.Report.Markdown do
  @moduledoc false
  # Renders a `Report.summary/2` (verbose, so the slowest queries carry their
  # SQL) as Markdown for an agent or a bug report (ADR 13). Pure string
  # building: every list is already capped by the summary, every table cell is
  # escaped, SQL that is long or multi-line goes in a fenced block under its
  # table, so a table row is always one line.

  @inline_sql 80
  @cell_max 300
  @errors_max 20

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
    "# #{plain(session.path || "unknown path")}#{view}"
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

    #{count(queries.count, "query", "queries")}#{failed}, #{ms(queries.total_us) || "0 ms"}.#{noise(queries)}

    ## Callbacks and renders

    #{count(summary.callbacks.count, "callback", "callbacks")}, \
    #{ms(summary.callbacks.total_us) || "0 ms"}. \
    #{count(summary.renders.count, "render", "renders")}.\
    """
  end

  defp noise(%{noise: %{count: n}}) when n > 0,
    do:
      " Plus #{count(n, "framework query", "framework queries")} (such as Phoenix.Ecto.CheckRepoStatus) not counted."

  defp noise(_queries), do: ""

  defp count(1, singular, _plural), do: "1 #{singular}"
  defp count(n, _singular, plural), do: "#{n} #{plural}"

  defp n_plus_one([]), do: nil

  defp n_plus_one(groups) do
    sql_table(
      "## N+1",
      "N",
      ["SQL", "Origin", "Count", "Callbacks", "Callers"],
      for g <- groups do
        {g.sql, [code(g.origin), g.count, ran_in(g.ran_in), callers(g.callers)]}
      end
    )
  end

  # "`DemoWeb.PageLive mount` ×7, ..." in one cell: one entry per callback
  # name, with its largest count and how many callbacks repeated it.
  defp ran_in([]), do: nil

  defp ran_in(places) do
    named = Enum.map(places, &{callback_name(&1), &1.count})

    named
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map_join(", ", fn name ->
      counts = for {^name, count} <- named, do: count
      "#{code(name)} ×#{Enum.max(counts)}#{times(length(counts))}"
    end)
  end

  defp times(1), do: ""
  defp times(n), do: " (#{n} callbacks)"

  defp callers([]), do: nil
  defp callers(callers), do: Enum.map_join(callers, ", ", &"#{code(&1.frame)} ×#{&1.count}")

  defp slowest_queries([]), do: nil

  defp slowest_queries(queries) do
    sql_table(
      "## Slowest queries",
      "Q",
      ["SQL", "Time", "Rows", "Callback", "Origin", "Caller"],
      for q <- queries do
        {q.sql,
         [
           ms(q.duration_us),
           q.rows,
           code(query_callback(q)),
           code(q.origin),
           code(if(q.caller != q.origin, do: q.caller))
         ]}
      end
    )
  end

  defp slowest_callbacks([]), do: nil

  defp slowest_callbacks(callbacks) do
    # Only inferred callbacks have an origin: the column is noise without one.
    origin? = Enum.any?(callbacks, & &1.origin)

    rows =
      for c <- callbacks do
        [code(callback_name(c)), ms(c.duration_us), c.queries] ++
          if(origin?, do: [code(c.origin)], else: [])
      end

    headers = ["Callback", "Time", "Queries"] ++ if(origin?, do: ["Origin"], else: [])
    table("## Slowest callbacks", headers, rows)
  end

  defp callback_name(c) do
    owner = c.component || c.view
    event = if c.event, do: " #{c.event}"
    inferred = if c[:inferred], do: " (inferred)"
    "#{if owner, do: inspect(owner) <> " "}#{c.callback}#{event}#{inferred}"
  end

  defp query_callback(%{callback: callback, event: nil}), do: to_string(callback)
  defp query_callback(%{callback: callback, event: event}), do: "#{callback} #{event}"

  defp unattributed(%{count: 0}), do: nil

  defp unattributed(%{origins: origins} = un) do
    rows = for o <- origins, do: [code(o.origin), o.count, ms(o.total_us)]

    table(
      "## Unattributed queries\n\n#{count(un.count, "query", "queries")} in no callback (usually handle_info or PubSub).",
      ["Origin", "Count", "Time"],
      rows
    )
  end

  defp errors([]), do: nil

  defp errors(errors) do
    {shown, rest} = Enum.split(errors, @errors_max)

    table =
      table(
        "## Errors",
        ["Source", "Message", "Origin"],
        for e <- shown do
          [plain(e.source), code(e.message), code(e.origin)]
        end
      )

    case length(rest) do
      0 -> table
      more -> table <> "\n\nand #{more} more (page_errors)"
    end
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
  defp sql_cell(sql, ref), do: if(fenced?(sql), do: "see #{ref}", else: code(sql))

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

  # Captured text (SQL, messages, origins) as one inline code span: nothing in
  # it is read as emphasis, HTML or a link. The span's backtick run is longer
  # than any inside; `|` stays escaped for the table.
  defp code(nil), do: nil

  defp code(value) do
    text = value |> one_line() |> String.replace("|", "\\|")
    ticks = String.duplicate("`", longest_run(text) + 1)
    pad = if String.starts_with?(text, "`") or String.ends_with?(text, "`"), do: " ", else: ""
    ticks <> pad <> text <> pad <> ticks
  end

  # Text outside code spans: every character Markdown or a table reads is escaped.
  defp plain(nil), do: nil

  defp plain(value) do
    value
    |> one_line()
    |> String.replace(~r/[\\|`<>*_\[\]]/, "\\\\\\0")
  end

  defp one_line(value) do
    value
    |> to_string()
    |> String.replace(~r/\s*[\r\n]+\s*/, " ")
    |> String.slice(0, @cell_max)
  end

  defp ms(nil), do: nil
  defp ms(us), do: "#{Float.round(us / 1000, 1)} ms"
end
