defmodule PhoenixDevToolbar.Plugins.RequestTest do
  # Attaches global handlers and uses the node global Store.
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.PageHelpers, only: [attach_plugins: 0]
  import PhoenixDevToolbar.ProcessHelpers
  import PhoenixDevToolbar.StackArgsHelpers
  import Plug.Test

  alias PhoenixDevToolbar.Attribution
  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Plugins.Request
  alias PhoenixDevToolbar.Report
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  setup do
    Store.reset()
    Collector.attach([Request])

    on_exit(fn ->
      attach_plugins()
      Store.reset()
    end)

    %Session{sid: sid} = Store.new_session(Session.new(:request))
    %{sid: sid}
  end

  defp dispatch(sid, method, path) do
    in_process(fn ->
      Attribution.track(sid)

      try do
        DemoWeb.Router.call(conn(method, path), DemoWeb.Router.init([]))
      catch
        _kind, reason -> {:raised, reason}
      end
    end)
  end

  test "records a routed request", %{sid: sid} do
    dispatch(sid, :get, "/hello/ada")

    assert [%Event{plugin: :request, kind: :dispatch, duration: duration, data: data}] =
             Store.events(sid)

    assert is_integer(duration)

    assert data == %{
             method: "GET",
             path: "/hello/ada",
             route: "/hello/:name",
             handler: ~s(DemoWeb.HelloPlug [greeting: "hi"]),
             status: 200,
             path_params: %{"name" => "ada"}
           }
  end

  test "keeps huge plug options and thrown terms bounded", %{sid: sid} do
    dispatch(sid, :get, "/big-opts")
    {_pid, {:raised, _}} = dispatch(sid, :get, "/throw")

    assert [%Event{kind: :dispatch, data: big}, %Event{kind: :exception, data: thrown}] =
             Store.events(sid)

    assert byte_size(big.handler) < 1_000
    assert big.handler =~ "..."
    assert thrown.error =~ "** (throw) [1, 2, 3"
    assert byte_size(thrown.error) < 1_000
  end

  test "records a request that raised, with the error and its origin", %{sid: sid} do
    {_pid, {:raised, _exception}} = dispatch(sid, :get, "/boom")

    assert [%Event{kind: :exception, data: data}] = Store.events(sid)
    assert data.route == "/boom"
    assert data.error =~ "boom"
    assert [origin | _] = data.stacktrace
    assert origin =~ "DemoWeb.BoomPlug.call/2"
  end

  describe "call arguments of a crash (stack_args, ADR 03)" do
    defp clause_errors(sid, config) do
      put_stack_args(config, [Request])
      dispatch(sid, :get, "/clause")
      Store.events(sid)
    end

    test "off by default: arity only, nothing for agents", %{sid: sid} do
      assert [%Event{kind: :exception, data: data}] = clause_errors(sid, false)
      assert [first | _] = data.stacktrace
      assert first =~ "DemoWeb.ClausePlug.strict/2"
      refute Map.has_key?(data, :stack_args)
      assert [error] = Report.errors(sid)
      refute Map.has_key?(error, :stack_args)
    end

    test "opted in: stored redacted, hidden from the report unless agents: true", %{sid: sid} do
      assert [%Event{kind: :exception, data: data}] = clause_errors(sid, true)
      assert [args | _] = data.stack_args
      assert args =~ "Plug.Conn"
      assert args =~ "[REDACTED]"
      refute args =~ "hunter2"
      assert [error] = Report.errors(sid)
      refute Map.has_key?(error, :stack_args)

      put_stack_args([agents: true], [Request])
      assert [%{stack_args: [^args | _]}] = Report.errors(sid)
    end
  end
end
