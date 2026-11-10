defmodule PhoenixDevToolbar.ReportPageTest do
  # The read API end to end (ADR 13): a real host page through DemoWeb.Endpoint,
  # its queries read back without a panel.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers

  alias PhoenixDevToolbar.Report

  @endpoint DemoWeb.Endpoint

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

    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "page_summary", "arguments" => %{"path" => "/demo"}}
    }

    conn =
      %{build_conn() | host: "localhost", remote_ip: {127, 0, 0, 1}}
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("mcp-protocol-version", "2025-06-18")
      |> post("/__pdt/mcp", Jason.encode!(body))

    assert %{"result" => %{"isError" => false, "structuredContent" => summary}} =
             json_response(conn, 200)

    assert summary["queries"]["count"] == expected.queries.count
    assert summary["queries"]["count"] == 1
    assert [^sid, live_sid] = summary["sids"]
    assert live_sid in expected.sids
    assert String.ends_with?(summary["panel_url"], "/__pdt/panel?sid=" <> sid)
  end
end
