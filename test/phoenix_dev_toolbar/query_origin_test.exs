defmodule PhoenixDevToolbar.QueryOriginTest do
  # The origin of a query run from a Task or start_async (ADR 08): the user's
  # `fn -> Repo.query(...) end` tail calls the repo, so only plumbing frames are
  # left. Real SQLite queries with `stacktrace: true`, through a host LiveView.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers

  alias PhoenixDevToolbar.Report

  setup :sqlite_plugins

  setup do
    {host, sid} = visit("/demo")
    %{host: host, sid: sid}
  end

  defp query(sid, param), do: sid |> Report.queries() |> Enum.find(&(&1.params =~ param))

  defp assert_not_plumbing(origin) do
    assert byte_size(origin) > 0
    refute origin =~ "Task.Supervised"
    refute origin =~ "Phoenix.LiveView.Async"
    refute origin =~ "proc_lib"
  end

  test "a query in Task.async names the task function or the owning callback",
       %{host: host, sid: sid} do
    render_hook(host, "task_query", %{})

    query = query(sid, "1")
    assert_not_plumbing(query.origin)
    assert query.origin =~ "DemoWeb.PageLive"
    assert [_ | _] = Report.summary(sid).queries.slowest
    assert Enum.all?(Report.summary(sid).queries.slowest, &(&1.origin == query.origin))
  end

  test "a query in start_async names the async function or the owning callback",
       %{host: host, sid: sid} do
    render_hook(host, "async_query", %{})
    render_async(host)

    query = query(sid, "2")
    assert_not_plumbing(query.origin)
    assert query.origin == "task in DemoWeb.PageLive"

    assert [%{origin: origin}] = Report.summary(sid).unattributed.origins
    assert origin == query.origin
  end
end
