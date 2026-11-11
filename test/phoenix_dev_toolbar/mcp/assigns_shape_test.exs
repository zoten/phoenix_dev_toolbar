defmodule PhoenixDevToolbar.Mcp.AssignsShapeTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.ReportFixtures

  alias PhoenixDevToolbar.Mcp.Json
  alias PhoenixDevToolbar.Mcp.Tools
  alias PhoenixDevToolbar.Store

  @endpoint DemoWeb.Endpoint
  @opts [base_url: "http://localhost:4000/__pdt"]
  @page_open "must be open in a browser"

  setup do
    Store.reset()
    on_exit(&Store.reset/0)

    {:ok, view, _html} = live_isolated(build_conn(), DemoWeb.ShapeLive)
    request = session(:request, path: "/shape")
    live = session(:live_view, parent: request.sid, owner: view.pid, path: "/shape")
    %{view: view, request: request, live: live}
  end

  defp shape!(args) do
    assert {:ok, result} = Tools.call("page_assigns_shape", args, @opts)
    result
  end

  defp entry(result, key), do: Enum.find(result["assigns"], &(&1["key"] == key))

  test "ranks assigns by size, flags streams and returns no values",
       %{request: request, live: live} do
    result = shape!(%{"path" => "/shape"})

    assert result["sid"] == request.sid
    assert result["view"] == "DemoWeb.ShapeLive"
    assert result["panel_url"] == "http://localhost:4000/__pdt/panel?sid=#{request.sid}"
    assert [%{"key" => ":big"} | _] = result["assigns"]

    assert %{"type" => "list", "length" => 1000, "stream?" => false, "words" => words} =
             entry(result, ":big")

    assert words >= 2000
    assert %{"type" => "list", "length" => 2} = entry(result, ":small")
    assert %{"type" => "binary", "length" => nil} = entry(result, ":title")

    assert %{"stream?" => true, "type" => "struct Phoenix.LiveView.LiveStream"} =
             entry(result, ":posts")

    assert result["total_words"] >= words
    refute Enum.any?(result["assigns"], &(&1["key"] in [":__changed__", ":streams"]))

    json = Json.encode!(result)
    refute json =~ "secret-title-value"
    refute json =~ "secret-post-name"

    assert shape!(%{"sid" => live.sid})["sid"] == live.sid
  end

  test "a dead owner and a page without a LiveView are tool errors",
       %{view: view, request: request} do
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    assert {:error, message} = Tools.call("page_assigns_shape", %{}, @opts)
    assert message =~ @page_open

    Store.reset()
    only_request = session(:request, path: "/plain")

    assert {:error, message} =
             Tools.call("page_assigns_shape", %{"sid" => only_request.sid}, @opts)

    assert message =~ @page_open
    refute request.sid == only_request.sid
  end

  test "a busy LiveView is a timeout tool error and keeps running", %{view: view} do
    send(view.pid, {:block, self()})
    assert_receive :blocked

    assert {:error, message} = Tools.call("page_assigns_shape", %{}, @opts)
    assert message =~ "timed out"
    assert message =~ "busy"

    send(view.pid, :unblock)
    assert %{"assigns" => [_ | _]} = shape!(%{})
  end
end
