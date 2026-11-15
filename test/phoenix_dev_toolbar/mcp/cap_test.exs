defmodule PhoenixDevToolbar.Mcp.CapTest do
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.ReportFixtures

  alias PhoenixDevToolbar.Mcp.Cap
  alias PhoenixDevToolbar.Mcp.Json
  alias PhoenixDevToolbar.Mcp.Tools
  alias PhoenixDevToolbar.Store

  @opts [base_url: "http://localhost:4000/__pdt"]

  setup do
    Store.reset()
    on_exit(&Store.reset/0)

    s = session(:request, path: "/big")
    for n <- 1..30, do: query(s, sql: "SELECT #{n} FROM t", us: n)
    {:ok, sid: s.sid}
  end

  defp call!(name, args, opts \\ @opts) do
    assert {:ok, result} = Tools.call(name, args, opts)
    result
  end

  defp page_all(name, args, key) do
    Stream.unfold(0, fn
      nil ->
        nil

      offset ->
        r = call!(name, Map.put(args, "offset", offset))
        {r[key], r["next_offset"]}
    end)
    |> Enum.to_list()
  end

  # What list_pages builds for `offset`, cut like the tool does.
  defp paged_rows(rows, offset, cap) do
    shown = Enum.drop(rows, offset)

    Cap.apply(
      "list_pages",
      %{"total" => length(rows), "returned" => length(shown), "pages" => shown},
      cap,
      offset
    )
  end

  defp size(result), do: byte_size(Json.encode!(result))

  describe "page_queries" do
    test "a result under the cap is untouched", %{sid: sid} do
      result = call!("page_queries", %{"sid" => sid, "limit" => 5})
      refute Map.has_key?(result, "truncated")
      refute Map.has_key?(result, "next_offset")
    end

    test "over the cap rows are cut from the end with next_offset and a hint", %{sid: sid} do
      result = call!("page_queries", %{"sid" => sid, "max_bytes" => 3_000})

      assert %{"truncated" => true, "total" => 30, "returned" => n, "next_offset" => n} = result
      assert n > 0 and n < 30
      assert length(result["queries"]) == n
      assert size(result) <= 3_000
      assert result["hint"] =~ "offset: #{n}"
      assert result["hint"] =~ "max_bytes"
      assert hd(result["queries"])["sql"] == "SELECT 1 FROM t"
    end

    test "paging with offset covers every row once", %{sid: sid} do
      pages = page_all("page_queries", %{"sid" => sid, "max_bytes" => 3_000}, "queries")

      sqls = pages |> List.flatten() |> Enum.map(& &1["sql"])
      assert sqls == for(n <- 1..30, do: "SELECT #{n} FROM t")
      assert length(pages) > 1
    end

    test "paging skips an oversize row in the middle and reaches every following row" do
      rows =
        for n <- 1..12,
            do: %{"id" => n, "pad" => String.duplicate("x", if(n == 6, do: 3_000, else: 20))}

      seen =
        0
        |> Stream.unfold(fn
          nil ->
            nil

          offset ->
            r = paged_rows(rows, offset, 1_000)
            {r["pages"], r["next_offset"]}
        end)
        |> Enum.to_list()
        |> List.flatten()
        |> Enum.map(& &1["id"])

      assert seen == for(n <- 1..12, n != 6, do: n)
    end

    test "an oversize row at offset gets next_offset skipping it and a hint saying so" do
      rows = [%{"id" => 1, "pad" => String.duplicate("x", 3_000)}, %{"id" => 2, "pad" => "y"}]

      result = paged_rows(rows, 0, 1_000)
      assert %{"truncated" => true, "returned" => 0, "pages" => [], "next_offset" => 1} = result
      assert result["hint"] =~ "row at offset 0 is larger than the cap"
      assert result["hint"] =~ "max_bytes: 0"
      assert result["hint"] =~ "offset: 1"
    end

    test "a row between the two bounds is skipped by next_offset, never the small cap dead end" do
      for pad <- 600..1_000, rem(pad, 7) == 0 do
        rows = [%{"id" => 1, "pad" => String.duplicate("x", pad)}, %{"id" => 2, "pad" => "y"}]
        result = paged_rows(rows, 0, 1_000)

        case result["returned"] do
          0 ->
            assert result["next_offset"] == 1, "pad #{pad}"
            assert result["hint"] =~ "larger than the cap", "pad #{pad}"

          _fits ->
            :ok
        end
      end
    end

    test "the narrowing hint names only arguments the tool accepts", %{sid: sid} do
      queries = call!("page_queries", %{"sid" => sid, "max_bytes" => 3_000})
      assert queries["hint"] =~ "group_by"

      for name <- ["page_errors", "recent_errors"] do
        rows = for n <- 1..30, do: %{"id" => n, "pad" => String.duplicate("x", 100)}
        result = Cap.apply(name, %{"total" => 30, "returned" => 30, "errors" => rows}, 1_500, 0)
        assert result["hint"] =~ "lower limit"
        refute result["hint"] =~ "group_by"
        refute result["hint"] =~ "verbose"
        refute result["hint"] =~ "filters"
      end
    end

    test "fixed fields over the cap get the cap too small hint, no next_offset", %{sid: sid} do
      result = call!("page_queries", %{"sid" => sid, "max_bytes" => 50})
      assert %{"truncated" => true, "returned" => 0, "queries" => []} = result
      refute Map.has_key?(result, "next_offset")
      assert result["hint"] =~ "too small"
      assert result["hint"] =~ "max_bytes"
    end

    test "the cut hint says its rows are those of this call", %{sid: sid} do
      result = call!("page_queries", %{"sid" => sid, "max_bytes" => 3_000})
      assert result["hint"] =~ ~r/cut to \d+ of the 30 rows of this call/
    end

    test "offset applies after sort and before limit, total stays full", %{sid: sid} do
      result =
        call!("page_queries", %{"sid" => sid, "sort" => "slowest", "offset" => 2, "limit" => 2})

      assert %{"total" => 30, "returned" => 2, "queries" => [a, b]} = result
      assert {a["sql"], b["sql"]} == {"SELECT 28 FROM t", "SELECT 27 FROM t"}

      assert %{"returned" => 0, "queries" => []} =
               call!("page_queries", %{"sid" => sid, "offset" => 99})
    end

    test "max_bytes: 0 is no cap and raises over the configured one", %{sid: sid} do
      opts = Keyword.put(@opts, :max_result_bytes, 1_000)

      assert %{"truncated" => true} = call!("page_queries", %{"sid" => sid}, opts)

      full = call!("page_queries", %{"sid" => sid, "max_bytes" => 0}, opts)
      refute Map.has_key?(full, "truncated")
      assert full["returned"] == 30

      assert %{"returned" => 30} =
               call!("page_queries", %{"sid" => sid, "max_bytes" => 50_000}, opts)
    end

    test ":infinity as the configured cap means no cap", %{sid: sid} do
      opts = Keyword.put(@opts, :max_result_bytes, :infinity)
      assert %{"returned" => 30} = call!("page_queries", %{"sid" => sid}, opts)
    end

    test "a single row larger than the cap leaves an empty list with the hint", %{sid: sid} do
      result = call!("page_queries", %{"sid" => sid, "max_bytes" => 400})
      assert %{"truncated" => true, "returned" => 0, "queries" => []} = result
      refute Map.has_key?(result, "next_offset")
      assert result["hint"] =~ "too small"
    end

    test "groups are cut too", %{sid: sid} do
      result = call!("page_queries", %{"sid" => sid, "group_by" => "sql", "max_bytes" => 2_000})
      assert %{"truncated" => true, "returned" => n, "groups" => groups} = result
      assert length(groups) == n and n < 30
      assert size(result) <= 2_000
    end

    test "bad max_bytes and offset are tool errors naming the argument", %{sid: sid} do
      for bad <- [-1, "9", 1.5] do
        assert {:error, message} = Tools.call("page_queries", %{"max_bytes" => bad}, @opts)
        assert message =~ "max_bytes: a non-negative integer"
      end

      assert {:error, message} =
               Tools.call("page_queries", %{"sid" => sid, "offset" => -1}, @opts)

      assert message =~ "offset: a non-negative integer"
    end
  end

  test "offset past the end is an empty list with the full total", %{sid: sid} do
    assert %{"returned" => 0, "queries" => [], "total" => 30} =
             call!("page_queries", %{"sid" => sid, "offset" => 99})

    assert %{"returned" => 0, "errors" => [], "total" => 0} =
             call!("page_errors", %{"sid" => sid, "offset" => 5})
  end

  test "offset on page_errors and recent_errors skips rows, total stays full" do
    s = session(:request, path: "/errs", started_at: 1_800_000_000_000_000)
    for m <- ~w(a b c), do: callback(s, :handle_info, error: m)

    assert %{"total" => 3, "returned" => 1, "errors" => [_]} =
             call!("page_errors", %{"sid" => s.sid, "offset" => 2})

    assert %{"total" => 3, "returned" => 0, "errors" => []} =
             call!("page_errors", %{"sid" => s.sid, "offset" => 3})

    assert %{"total" => 3, "returned" => 2} = call!("recent_errors", %{"offset" => 1})
    assert %{"total" => 3, "returned" => 0} = call!("recent_errors", %{"offset" => 7})
  end

  test "page_assigns_shape rows are cut with next_offset through Cap" do
    assigns = for n <- 1..40, do: %{"name" => "assign_#{n}", "kind" => "map"}
    result = %{"sid" => "x", "assigns" => assigns}

    cut = Cap.apply("page_assigns_shape", result, 800, 10)
    assert %{"truncated" => true, "assigns" => kept, "next_offset" => next} = cut
    assert next == 10 + length(kept) and length(kept) < 40
    assert byte_size(Json.encode!(cut)) <= 800
  end

  test "list_pages pages with offset and is cut by max_bytes" do
    for n <- 1..20, do: session(:request, path: "/p#{n}", started_at: 1_800_000_000_000_000 + n)

    assert %{"pages" => [%{"path" => "/p18"}]} =
             call!("list_pages", %{"offset" => 2, "limit" => 1, "path_prefix" => "/p"})

    result = call!("list_pages", %{"limit" => 20, "max_bytes" => 2_000})
    assert %{"truncated" => true, "next_offset" => n, "pages" => pages} = result
    assert length(pages) == n and n < 20
  end

  test "page_summary lists are shortened, longest first, with a hint and no next_offset",
       %{sid: sid} do
    full = call!("page_summary", %{"sid" => sid, "verbose" => true, "max_bytes" => 0})
    cap = size(full) - 300
    result = call!("page_summary", %{"sid" => sid, "verbose" => true, "max_bytes" => cap})

    assert %{"truncated" => true, "hint" => hint} = result
    refute Map.has_key?(result, "next_offset")
    assert hint =~ "page_queries"
    assert size(result) <= cap
    assert length(result["queries"]["slowest"]) < length(full["queries"]["slowest"])
  end

  describe "page_report" do
    test "the Markdown is cut on a UTF-8 boundary and keeps its footer", %{sid: sid} do
      full = call!("page_report", %{"sid" => sid, "max_bytes" => 0})
      refute Map.has_key?(full, "truncated")
      footer = "\n---\nsid `#{sid}`, panel: #{full["panel_url"]}\n"
      assert String.ends_with?(full["markdown"], footer)

      for cap <- [600, 601, 602, 603] do
        result = call!("page_report", %{"sid" => sid, "max_bytes" => cap})
        assert %{"truncated" => true, "markdown" => md} = result
        assert String.valid?(md)
        assert byte_size(md) <= cap
        assert String.ends_with?(md, footer)
        assert md =~ "Report cut"
        assert md =~ "page_queries"
        assert result["hint"] =~ "client's tool result limit"
      end
    end

    test "multi-byte text is never split" do
      s = session(:request, path: "/ünï/日本語/日本語/日本語/日本語/日本語")
      for _ <- 1..10, do: query(s, sql: String.duplicate("日", 40))

      for cap <- 520..540 do
        assert %{"markdown" => md} = call!("page_report", %{"sid" => s.sid, "max_bytes" => cap})
        assert String.valid?(md)
      end
    end
  end

  test "tools without rows (page_n_plus_one, compare_pages) are cut at their longest list" do
    findings = for n <- 1..50, do: %{"sql" => "SELECT #{n}", "count" => n}
    result = %{"sid" => "x", "n_plus_one" => findings}

    cut = Cap.apply("page_n_plus_one", result, 500, nil)
    assert %{"truncated" => true, "n_plus_one" => kept, "hint" => hint} = cut
    assert length(kept) < 50 and kept == Enum.take(findings, length(kept))
    assert byte_size(Json.encode!(cut)) <= 500
    assert hint =~ "max_bytes"
    refute Map.has_key?(cut, "next_offset")

    assert Cap.apply("compare_pages", result, :infinity, nil) == result
  end

  test "every tool accepts max_bytes in its schema" do
    for tool <- Tools.list() do
      assert %{"type" => "integer", "minimum" => 0} =
               tool["inputSchema"]["properties"]["max_bytes"]
    end
  end
end
