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
  @fast_opts Keyword.put(@opts, :assigns_timeout, 50)
  @gone "LiveView is gone (tab closed or navigated away): open the page in a browser"
  @no_live_view "has no LiveView (a dead render only"

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

    words_by_rank = Enum.map(result["assigns"], & &1["words"])
    assert words_by_rank == Enum.sort(words_by_rank, :desc)
    assert result["total_words"] == Enum.sum(words_by_rank)
    refute Enum.any?(result["assigns"], &(&1["key"] in [":__changed__", ":streams"]))

    json = Json.encode!(result)
    refute json =~ "secret-title-value"
    refute json =~ "secret-post-name"
    refute json =~ "secret-odd-struct"
    assert %{"type" => "map"} = entry(result, ":odd")
    assert result["live_view_sid"] == live.sid
    assert result["live_view_path"] == "/shape"
    refute Map.has_key?(result, "warning")
  end

  test "an explicit connected mount sid reads as its page (ADR 13)",
       %{request: request, live: live} do
    by_mount = shape!(%{"sid" => live.sid})
    assert by_mount["sid"] == request.sid
    assert by_mount["live_view_sid"] == live.sid
  end

  test "a dead owner and a page without a LiveView are tool errors",
       %{view: view} do
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    assert {:error, message} = Tools.call("page_assigns_shape", %{}, @opts)
    assert message =~ @gone

    Store.reset()
    only_request = session(:request, path: "/plain")

    assert {:error, message} =
             Tools.call("page_assigns_shape", %{"sid" => only_request.sid}, @opts)

    assert message =~ @no_live_view
    refute message =~ "gone"
  end

  test "a newer dead render yields to an older capture of the path with a live LiveView",
       %{request: request, live: live} do
    newer = session(:request, path: "/shape", started_at: 1_800_000_000_000_000 + 100)

    result = shape!(%{"path" => "/shape"})
    assert result["sid"] == request.sid
    assert result["live_view_sid"] == live.sid
    assert result["note"] =~ newer.sid
    assert result["note"] =~ request.sid

    # An explicit sid is read as asked: no silent swap.
    assert {:error, message} = Tools.call("page_assigns_shape", %{"sid" => newer.sid}, @opts)
    assert message =~ @no_live_view

    # No note when the newest page is the live one.
    Store.reset()
    {:ok, view, _html} = live_isolated(build_conn(), DemoWeb.ShapeLive)
    only = session(:request, path: "/shape")
    session(:live_view, parent: only.sid, owner: view.pid, path: "/shape")
    refute Map.has_key?(shape!(%{"path" => "/shape"}), "note")
  end

  test "with no arguments the fallback stays on the newest page's path",
       %{request: request, live: live} do
    # The newest capture is a dead render of another path: a LiveView of /shape
    # must not be read for it.
    other = session(:request, path: "/other", started_at: 1_800_000_000_000_000 + 100)

    assert {:error, message} = Tools.call("page_assigns_shape", %{}, @opts)
    assert message =~ @no_live_view

    # Same path: the fallback still applies.
    newer = session(:request, path: "/shape", started_at: 1_800_000_000_000_000 + 200)
    result = shape!(%{})
    assert result["sid"] == request.sid
    assert result["live_view_sid"] == live.sid
    assert result["note"] =~ newer.sid
    refute result["note"] =~ other.sid
  end

  test "a newest dead render with only closed tabs behind it has no LiveView to read",
       %{view: view} do
    session(:request, path: "/shape", started_at: 1_800_000_000_000_000 + 100)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    assert {:error, message} = Tools.call("page_assigns_shape", %{"path" => "/shape"}, @opts)
    assert message =~ @no_live_view
  end

  test "after live navigation the result names the LiveView actually read",
       %{request: request, live: live} do
    {:ok, other, _html} = live_isolated(build_conn(), DemoWeb.ShapeLive)
    transport = self()
    Store.claim(live.sid, live.owner, transport)

    navigated =
      session(:live_view,
        parent: live.sid,
        owner: other.pid,
        transport: transport,
        path: "/shape/next",
        started_at: 1_800_000_000_000_000 + 10
      )

    result = shape!(%{"sid" => request.sid})
    assert result["sid"] == request.sid
    assert result["live_view_sid"] == navigated.sid
    assert result["live_view_path"] == "/shape/next"
    assert result["warning"] =~ "navigated to /shape/next"
    assert result["warning"] =~ "/shape"
  end

  test "a busy LiveView is a timeout tool error and keeps running", %{view: view} do
    Process.flag(:trap_exit, true)
    send(view.pid, {:block, self()})
    assert_receive :blocked

    {:messages, before} = Process.info(self(), :messages)

    assert {:error, message} = Tools.call("page_assigns_shape", %{}, @fast_opts)
    assert message =~ "timed out"
    assert message =~ "busy"
    # The killed reader leaves nothing behind in the caller's mailbox.
    assert {:messages, ^before} = Process.info(self(), :messages)

    # The reader is not linked to the caller and leaves nothing behind.
    refute_received {:EXIT, _pid, _reason}
    refute_received {:DOWN, _ref, :process, _pid, _reason}

    send(view.pid, :unblock)
    assert %{"assigns" => [_ | _]} = shape!(%{})
  end
end
