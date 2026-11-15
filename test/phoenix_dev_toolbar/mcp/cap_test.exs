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
      pages =
        Stream.unfold(0, fn
          nil ->
            nil

          offset ->
            r = call!("page_queries", %{"sid" => sid, "max_bytes" => 3_000, "offset" => offset})
            {r["queries"], r["next_offset"]}
        end)
        |> Enum.to_list()

      sqls = pages |> List.flatten() |> Enum.map(& &1["sql"])
      assert sqls == for(n <- 1..30, do: "SELECT #{n} FROM t")
      assert length(pages) > 1
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
      assert result["hint"] =~ "single row"
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
