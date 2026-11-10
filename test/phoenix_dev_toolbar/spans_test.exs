defmodule PhoenixDevToolbar.SpansTest do
  # Callback spans (ADR 02): every event is stamped with the LiveView callback
  # it happened in, so diagnostics can group "one callback". Drives a real host
  # LiveView through DemoWeb.Endpoint.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhoenixDevToolbar.Attribution
  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.ProcessHelpers
  alias PhoenixDevToolbar.Store

  @endpoint DemoWeb.Endpoint

  setup do
    Store.reset()
    Application.put_env(:phoenix_dev_toolbar, :repos, [DemoWeb.FakeRepo])
    Collector.attach(PhoenixDevToolbar.Application.plugins())

    on_exit(fn ->
      Application.put_env(:phoenix_dev_toolbar, :repos, [DemoWeb.SQLiteRepo])
      Collector.attach(PhoenixDevToolbar.Application.plugins())
      Store.reset()
    end)

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("accept", "text/html")
      |> Plug.Conn.put_req_header("sec-fetch-dest", "document")
      |> get("/demo")

    {:ok, host, _html} = live(conn)
    {sid, _span} = Store.caller(host.pid)
    %{host: host, sid: sid}
  end

  defp queries(sid, sql),
    do: for(%Event{kind: :query} = e <- Store.events(sid), e.data.sql == sql, do: e)

  # The spans of the handle_event callbacks, in order (recorded at their stop).
  defp handle_event_spans(sid) do
    for %Event{kind: :callback, span: span, data: %{callback: :handle_event}} <- Store.events(sid),
        do: span
  end

  test "queries in one callback share its span; the next callback gets another",
       %{host: host, sid: sid} do
    render_hook(host, "queries", %{"sql" => "SELECT a", "count" => 3})
    render_hook(host, "queries", %{"sql" => "SELECT b", "count" => 1})

    [a1, a2, a3] = queries(sid, "SELECT a")
    [b] = queries(sid, "SELECT b")

    assert a1.span == a2.span and a2.span == a3.span
    assert handle_event_spans(sid) == [a1.span, b.span]
    refute b.span == a1.span
  end

  test "a Task.async child gets the span of the callback it was called from",
       %{host: host, sid: sid} do
    render_hook(host, "queries", %{"sql" => "SELECT t", "count" => 2, "task" => true})

    [t1, t2] = queries(sid, "SELECT t")

    assert t1.data.caller? and t2.data.caller?
    assert t1.span == t2.span
    assert handle_event_spans(sid) == [t1.span]
  end

  describe "span ids" do
    test "two processes of one sid (nested LiveViews) never share a span" do
      {_a, span_a} = ProcessHelpers.in_process(fn -> track_and_bump("shared") end)
      {_b, span_b} = ProcessHelpers.in_process(fn -> track_and_bump("shared") end)

      refute span_a == span_b
    end

    test "a re-tracked process and its $callers children agree on the span" do
      {_pid, {own, child}} =
        ProcessHelpers.in_process(fn ->
          track_and_bump("first")
          Attribution.track("second")
          {_sid, :self, own} = Attribution.current()
          child = fn -> Attribution.current() end |> Task.async() |> Task.await()
          {own, child}
        end)

      assert {"second", :caller, ^own} = child
    end

    test "an untracked process gets no span" do
      {_pid, result} =
        ProcessHelpers.in_process(fn ->
          # Real shaped measurements and metadata: other handlers (LiveView's
          # own logger) are attached to this event and would be detached.
          :telemetry.execute(
            [:phoenix, :live_view, :handle_event, :start],
            %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
            %{socket: %Phoenix.LiveView.Socket{view: DemoWeb.PageLive}, event: "x", params: %{}}
          )

          {Attribution.current(), Process.get(:pdt_span)}
        end)

      assert result == {nil, nil}
    end

    defp track_and_bump(sid) do
      Attribution.track(sid)
      Attribution.next_span()
    end
  end
end
