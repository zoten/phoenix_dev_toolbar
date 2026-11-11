defmodule PhoenixDevToolbar.EctoDetailsPanelTest do
  # A query row renders its details (params, stacktrace, timings) only when
  # expanded (ADR 04, lazy tabs): collapsed rows carry the toggle alone.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers
  import PhoenixDevToolbar.ReportFixtures

  alias PhoenixDevToolbar.Store

  setup do
    Store.reset()
    on_exit(&Store.reset/0)

    request = session(:request, path: "/demo")
    live = session(:live_view, parent: request.sid, path: "/demo", view: DemoWeb.PageLive)
    query(live, sql: "SELECT 1", stacktrace: ["lib/demo/thing.ex:10: Demo.Thing.run/0"])
    panel = open_panel(request.sid)
    [seq] = query_row_seqs(panel)
    %{panel: panel, seq: seq}
  end

  test "a collapsed row has no details until its toggle is clicked", %{panel: panel, seq: seq} do
    row = "#pdt-query-#{seq}"
    toggle = "#pdt-details-toggle-#{seq}"

    assert has_element?(panel, "#{row} #{toggle}[aria-expanded=false]")
    refute has_element?(panel, "#{row} .pdt-details pre")
    refute has_element?(panel, "#{row} .pdt-details dl")

    panel |> element(toggle) |> render_click()
    assert has_element?(panel, "#{row} #{toggle}[aria-expanded=true]")
    assert has_element?(panel, "#{row} .pdt-details pre", "Demo.Thing.run/0")
    assert has_element?(panel, "#{row} .pdt-details dd code")

    panel |> element(toggle) |> render_click()
    refute has_element?(panel, "#{row} .pdt-details pre")
    assert has_element?(panel, "#{row} #{toggle}[aria-expanded=false]")
  end

  test "a malformed or unknown toggle is ignored", %{panel: panel, seq: seq} do
    toggle = "#pdt-details-toggle-#{seq}"

    for params <- [%{"seq" => "x"}, %{"seq" => "999999"}, %{"seq" => %{"a" => 1}}] do
      panel |> element(toggle) |> render_click(params)
    end

    refute has_element?(panel, "#pdt-query-#{seq} .pdt-details dl")

    # The tab still works: a real toggle opens the details.
    panel |> element(toggle) |> render_click()
    assert has_element?(panel, "#{toggle}[aria-expanded=true]")
    assert has_element?(panel, "#pdt-query-#{seq} .pdt-details dl")
  end
end
