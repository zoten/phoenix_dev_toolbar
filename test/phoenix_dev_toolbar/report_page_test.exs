defmodule PhoenixDevToolbar.ReportPageTest do
  # The read API end to end (ADR 13): a real host page through DemoWeb.Endpoint,
  # its queries read back without a panel.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.McpHelpers, only: [mcp_call: 2]
  import PhoenixDevToolbar.PageHelpers

  alias PhoenixDevToolbar.Report
  alias PhoenixDevToolbar.Store

  setup :sqlite_plugins

  test "a visited page reads back as one summary: request, LiveView, queries, callbacks" do
    {host, sid} = visit("/demo")

    render_hook(host, "sqlite", %{"sql" => "SELECT name FROM users WHERE id = ?", "params" => [1]})

    assert %{sid: ^sid, kind: :request} = Report.latest(path: "/demo", kind: :request)

    summary = Report.summary(sid)
    assert [^sid, live_sid] = summary.sids
    assert %{kind: :live_view, view: DemoWeb.PageLive} = Report.latest(kind: :live_view)
    assert %{path: "/demo", status: 200} = summary.request
    assert %{count: 1, failed: 0} = summary.queries

    assert [%{sid: ^live_sid, sql: "SELECT name FROM users WHERE id = ?", rows: 1}] =
             Report.queries(sid)

    assert %{callback: :handle_event, event: "sqlite", queries: 1} =
             sid |> Report.callbacks() |> Enum.find(&(&1.callback == :handle_event))
  end

  test "the MCP endpoint summarises the same captured page" do
    {host, sid} = visit("/demo")

    render_hook(host, "sqlite", %{"sql" => "SELECT name FROM users WHERE id = ?", "params" => [1]})

    expected = Report.summary(sid)
    summary = mcp_call("page_summary", %{"path" => "/demo"})

    assert summary["queries"]["count"] == expected.queries.count
    assert summary["queries"]["count"] == 1
    assert [^sid, live_sid] = summary["sids"]
    assert live_sid in expected.sids
    assert String.ends_with?(summary["panel_url"], "/__pdt/panel?sid=" <> sid)
  end

  test "compare_pages over HTTP: the page visited twice (dead render and connected mount)" do
    {first, before_sid} = visit("/demo")
    {second, after_sid} = visit("/demo")
    assert before_sid != after_sid

    render_hook(second, "sqlite", %{
      "sql" => "SELECT name FROM users WHERE id = ?",
      "params" => [1]
    })

    # Flush the first view's pending messages before reading the report.
    _ = render(first)

    result = mcp_call("compare_pages", %{"before" => before_sid})

    assert %{"sid" => ^before_sid, "panel_url" => before_url} = result["before"]
    assert %{"sid" => ^after_sid, "panel_url" => after_url} = result["after"]
    assert before_url == "http://localhost/__pdt/panel?sid=" <> before_sid
    assert after_url == "http://localhost/__pdt/panel?sid=" <> after_sid
    assert %{"delta" => %{"count" => 1}} = result["queries"]
  end

  test "recent_errors over HTTP after a failing event on a real LiveView" do
    {view, sid} = visit("/demo/boom")
    Process.flag(:trap_exit, true)

    capture_log(fn ->
      catch_exit(render_hook(view, "strict", %{"ok" => false}))
    end)

    assert %{"errors" => errors} = mcp_call("recent_errors", %{})
    assert %{"page_sid" => ^sid, "path" => "/demo/boom", "panel_url" => url} = hd(errors)
    assert url == "http://localhost/__pdt/panel?sid=" <> sid
  end

  test "page_assigns_shape over HTTP reads the connected LiveView through its owner pid" do
    {host, sid} = visit("/demo")
    assert [%{owner: owner}] = for(s <- Store.sessions(), s.kind == :live_view, do: s)
    assert owner == host.pid

    shape = mcp_call("page_assigns_shape", %{"sid" => sid})

    assert shape["sid"] == sid
    assert shape["view"] == "DemoWeb.PageLive"
    assert shape["live_view_path"] == "/demo"
    refute Map.has_key?(shape, "warning")

    assert %{"key" => ":live_action", "type" => "atom", "words" => 0} =
             Enum.find(shape["assigns"], &(&1["key"] == ":live_action"))
  end

  test "page_report over HTTP ends with the sid and panel link" do
    {_host, sid} = visit("/demo")

    assert %{"markdown" => markdown, "panel_url" => url} =
             mcp_call("page_report", %{"sid" => sid})

    assert String.ends_with?(markdown, "sid `#{sid}`, panel: #{url}\n")
  end

  describe "a host endpoint with Phoenix.Ecto.CheckRepoStatus" do
    setup do
      Application.put_env(:pdt_check_repo_status, :ecto_repos, [DemoWeb.SQLiteRepo])
      on_exit(fn -> Application.delete_env(:pdt_check_repo_status, :ecto_repos) end)
    end

    test "its queries are kept, tagged as noise, left out of the counts and dimmed" do
      {host, sid} = visit("/demo")

      render_hook(host, "sqlite", %{
        "sql" => "SELECT name FROM users WHERE id = ?",
        "params" => [1]
      })

      {noise, app} = sid |> Report.queries() |> Enum.split_with(&(&1.noise != nil))

      assert [_ | _] = noise

      assert Enum.all?(
               noise,
               &(&1.noise == "check_repo_status" and &1.sql =~ "schema_migrations")
             )

      assert [%{sql: "SELECT name FROM users WHERE id = ?", noise: nil}] = app

      noise_count = length(noise)
      assert %{count: 1, noise: %{count: ^noise_count}} = Report.summary(sid).queries
      assert Report.markdown(sid) =~ "Plus #{noise_count} framework quer"

      panel = open_panel(sid)
      assert panel |> element("#pdt-badge-ecto-queries") |> render() =~ "1 query"
      open_panel_tab(panel, "ecto")

      for %{seq: seq} <- noise do
        assert has_element?(panel, "#pdt-query-#{seq}[data-pdt-noise] #pdt-noise-#{seq}")
      end
    end
  end
end
