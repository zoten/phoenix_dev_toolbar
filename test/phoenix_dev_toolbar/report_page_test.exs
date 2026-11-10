defmodule PhoenixDevToolbar.ReportPageTest do
  # The read API end to end (ADR 13): a real host page through DemoWeb.Endpoint,
  # its queries read back without a panel.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers

  alias PhoenixDevToolbar.Report

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
end
