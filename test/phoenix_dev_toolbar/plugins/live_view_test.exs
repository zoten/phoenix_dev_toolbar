defmodule PhoenixDevToolbar.Plugins.LiveViewTest do
  # Attaches global handlers and uses the node global Store.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers, only: [attach_plugins: 0, ms: 1]
  import PhoenixDevToolbar.ProcessHelpers

  alias Phoenix.LiveView.Socket
  alias PhoenixDevToolbar.Attribution
  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Plugins.LiveView, as: LiveViewPlugin
  alias PhoenixDevToolbar.Report
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @endpoint DemoWeb.Endpoint
  @lv [:phoenix, :live_view]
  @lc [:phoenix, :live_component]

  setup do
    Store.reset()
    Collector.attach([LiveViewPlugin])

    on_exit(fn ->
      attach_plugins()
      Store.reset()
    end)

    %Session{sid: sid} = Store.new_session(Session.new(:live_view))
    %{sid: sid}
  end

  # Sockets come from LiveView's public API, as the real callbacks produce them.
  defp socket(assigns \\ []),
    do: Phoenix.Component.assign(%Socket{view: DemoWeb.PageLive}, assigns)

  # Emits `events` ({name, measurements, metadata}) from a process tracked as `sid`.
  defp emit(sid, events) do
    in_process(fn ->
      Attribution.track(sid)

      Enum.each(events, fn {name, measurements, metadata} ->
        :telemetry.execute(name, measurements, metadata)
      end)
    end)

    :ok
  end

  # LiveView 1.2 added a render span for a component rendered on its own
  # (after its handle_event or a send_update); 1.1 has none.
  defp component_render_spans? do
    :phoenix_live_view |> Application.spec(:vsn) |> to_string() |> Version.match?(">= 1.2.0")
  end

  defp callbacks(sid), do: for(%Event{kind: :callback} = e <- Store.events(sid), do: e)
  defp renders(sid), do: for(%Event{kind: :render} = e <- Store.events(sid), do: e)

  describe "callbacks" do
    test "handle_event records the event, redacted params, the assigns diff and pushes",
         %{sid: sid} do
      socket =
        socket(count: 1, password_hash: "x")
        |> Phoenix.LiveView.push_event("highlight", %{secret: "never stored"})

      emit(sid, [
        {@lv ++ [:handle_event, :stop], %{duration: ms(3)},
         %{socket: socket, event: "save", params: %{"password" => "hunter2", "name" => "Ada"}}}
      ])

      assert [%Event{plugin: :live_view, duration: 3000, data: data}] = callbacks(sid)

      assert %{
               callback: :handle_event,
               view: DemoWeb.PageLive,
               component: nil,
               event: "save",
               connected?: false,
               pushed: ["highlight"],
               changes: %{keys: [:count, :password_hash], omitted: 0, values: values}
             } = data

      assert data.params =~ "Ada"
      refute data.params =~ "hunter2"
      assert values.password_hash == ~s("[REDACTED]")
      refute inspect(data) =~ "never stored"
    end

    test "mount and handle_params record their callback and params", %{sid: sid} do
      emit(sid, [
        {@lv ++ [:mount, :stop], %{duration: ms(1)},
         %{socket: socket(a: 1), params: %{}, session: %{}, uri: nil}},
        {@lv ++ [:handle_params, :stop], %{duration: ms(2)},
         %{socket: socket(), params: %{"page" => "2"}, uri: "http://localhost/users?page=2"}}
      ])

      assert [%Event{data: mount}, %Event{data: params}] = callbacks(sid)
      assert %{callback: :mount, changes: %{keys: [:a]}} = mount

      assert %{callback: :handle_params, params: ~s(%{"page" => "2"}), changes: %{keys: []}} =
               params
    end

    test "flags callbacks of a nested LiveView", %{sid: sid} do
      nested = %{socket() | parent_pid: self()}

      emit(sid, [
        {@lv ++ [:handle_event, :stop], %{duration: 1},
         %{socket: nested, event: "ping", params: %{}}},
        {@lv ++ [:handle_event, :stop], %{duration: 1},
         %{socket: socket(), event: "root", params: %{}}}
      ])

      assert [%Event{data: %{nested?: true}}, %Event{data: %{nested?: false}}] = callbacks(sid)
    end

    test "an exception records the error, without a diff", %{sid: sid} do
      emit(sid, [
        {@lv ++ [:handle_event, :exception], %{duration: ms(1)},
         %{
           socket: socket(),
           event: "boom",
           params: %{},
           kind: :error,
           reason: %RuntimeError{message: "bad"},
           stacktrace: []
         }}
      ])

      assert [%Event{data: %{callback: :handle_event, error: error} = data}] = callbacks(sid)
      assert error =~ "RuntimeError"
      assert error =~ "bad"
      assert data.changes == nil
    end

    test "component handle_event names the component and diffs its assigns", %{sid: sid} do
      # LiveView sets `myself` and `id` itself (`assign/3` refuses them).
      component_socket = %Socket{
        view: DemoWeb.PageLive,
        assigns: %{
          __changed__: %{count: true},
          count: 2,
          myself: %Phoenix.LiveComponent.CID{cid: 3},
          id: "counter"
        }
      }

      emit(sid, [
        {@lc ++ [:handle_event, :stop], %{duration: ms(1)},
         %{
           socket: component_socket,
           component: DemoWeb.CounterComponent,
           event: "inc",
           params: %{}
         }}
      ])

      assert [%Event{data: data}] = callbacks(sid)

      assert %{
               callback: :handle_event,
               component: DemoWeb.CounterComponent,
               cid: 3,
               id: ~s("counter")
             } = data

      assert :count in data.changes.keys
    end

    test "component update is timed, not diffed", %{sid: sid} do
      sockets = for id <- ["a", "b"], do: {%{id: id}, socket()}

      emit(sid, [
        {@lc ++ [:update, :stop], %{duration: ms(2)},
         %{socket: socket(), component: DemoWeb.CounterComponent, assigns_sockets: sockets}}
      ])

      assert [%Event{duration: 2000, data: data}] = callbacks(sid)

      assert %{
               callback: :update,
               component: DemoWeb.CounterComponent,
               count: 2,
               id: ~s("a"),
               changes: nil
             } = data
    end

    test "untracked processes and $callers children record nothing", %{sid: sid} do
      metadata = %{socket: socket(a: 1), event: "x", params: %{}}

      in_process(fn ->
        :telemetry.execute(@lv ++ [:handle_event, :stop], %{duration: 1}, metadata)
      end)

      in_process(fn ->
        Attribution.track(sid)

        task =
          Task.async(fn ->
            :telemetry.execute(@lv ++ [:handle_event, :stop], %{duration: 1}, metadata)
          end)

        Task.await(task)
      end)

      assert callbacks(sid) == []
    end
  end

  describe "renders" do
    defp component_render(cid, us) do
      {@lv ++ [:render, :stop], %{duration: System.convert_time_unit(us, :microsecond, :native)},
       %{
         socket: socket(),
         component: DemoWeb.CounterComponent,
         id: "c#{cid}",
         cid: cid,
         force?: false,
         changed?: true
       }}
    end

    defp view_render(stage, extra \\ %{}),
      do:
        {@lv ++ [:render, stage], %{duration: ms(4)},
         Map.merge(%{socket: socket(), force?: false, changed?: true}, extra)}

    test "records a LiveView render", %{sid: sid} do
      emit(sid, [view_render(:stop)])

      assert [%Event{duration: 4000, data: data}] = renders(sid)
      assert %{view: DemoWeb.PageLive, component: nil, changed?: true, error: nil} = data
    end

    test "a render that raises records the error", %{sid: sid} do
      emit(sid, [view_render(:exception, %{kind: :error, reason: :boom, stacktrace: []})])

      assert [%Event{data: %{error: error}}] = renders(sid)
      assert error =~ "boom"
    end

    test "a component rendered on its own is recorded with its cid and id", %{sid: sid} do
      emit(sid, [component_render(5, 250)])

      assert [
               %Event{
                 duration: 250,
                 data: %{component: DemoWeb.CounterComponent, cid: 5, id: ~s("c5")}
               }
             ] = renders(sid)
    end
  end

  describe "end to end with a real host LiveView" do
    setup do
      attach_plugins()
      :ok
    end

    test "records mounts, a click, a component event and its renders" do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("accept", "text/html")
        |> Plug.Conn.put_req_header("sec-fetch-dest", "document")
        |> get("/demo/components")

      {:ok, view, _html} = live(conn)
      view |> render_hook("click", %{})
      view |> element("#counter-inc") |> render_click()

      [session] =
        for s <- Store.sessions(), s.kind == :live_view, s.view == DemoWeb.ComponentsLive, do: s

      events = Store.events(session.sid)

      callbacks =
        for %Event{kind: :callback, data: d} <- events, do: {d.callback, d.component, d[:event]}

      assert {:mount, nil, nil} in callbacks
      assert {:handle_event, nil, "click"} in callbacks
      assert {:handle_event, DemoWeb.CounterComponent, "inc"} in callbacks
      assert {:update, DemoWeb.CounterComponent, nil} in callbacks

      click = Enum.find(events, &(&1.kind == :callback and &1.data[:event] == "click"))
      assert click.data.pushed == ["highlight"]
      assert click.data.changes.keys == [:clicks]

      mount = Enum.find(events, &(&1.kind == :callback and &1.data.callback == :mount))
      assert mount.data.changes.values.api_token == ~s("[REDACTED]")

      assert Enum.any?(events, &(&1.kind == :render and &1.data.component == nil))

      assert Enum.any?(
               events,
               &(&1.kind == :render and &1.data.component == DemoWeb.CounterComponent)
             ) ==
               component_render_spans?()
    end
  end

  describe "exception stacktraces with a real host LiveView" do
    setup do
      attach_plugins()
      :ok
    end

    defp boom_view do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("accept", "text/html")
        |> Plug.Conn.put_req_header("sec-fetch-dest", "document")
        |> get("/demo/boom")

      {:ok, view, _html} = live(conn)
      view
    end

    # The view process crashes and takes the test process with it unless trapped.
    defp crash(fun) do
      Process.flag(:trap_exit, true)
      capture_log(fn -> catch_exit(fun.()) end)
    end

    defp boom_errors do
      [session] =
        for s <- Store.sessions(), s.kind == :live_view, s.view == DemoWeb.BoomLive, do: s

      for %{source: :live_view} = error <- Report.errors(session.sid), do: error
    end

    test "a LiveComponent handle_event that raises keeps its stacktrace" do
      view = boom_view()
      crash(fn -> view |> element("#boom-component") |> render_click() end)

      assert [%{message: message, stacktrace: [first | _] = frames}] = boom_errors()
      assert message =~ "bad component event"
      assert first =~ "DemoWeb.BoomComponent.handle_event/3"
      assert length(frames) <= 10
      refute Enum.any?(frames, &(&1 =~ "PhoenixDevToolbar"))

      # Cut after the last host frame plus one: nothing deeper than that.
      last_host = Enum.find_index(Enum.reverse(frames), &(&1 =~ "DemoWeb."))
      assert last_host == 1
    end

    test "a render that raises keeps its stacktrace" do
      view = boom_view()
      crash(fn -> render_hook(view, "break", %{}) end)

      assert [%{message: message, stacktrace: [first | _]} | _] = boom_errors()
      assert message =~ "bad render"
      assert first =~ "DemoWeb.BoomLive.state/1"
    end

    test "a FunctionClauseError prints the arity, never the call's params or socket" do
      view = boom_view()
      params = %{"user" => %{"password" => "hunter2", "bio" => String.duplicate("x", 50_000)}}
      crash(fn -> render_hook(view, "strict", params) end)

      assert [%{stacktrace: [first | _] = frames, origin: origin} = error] = boom_errors()
      assert first =~ "DemoWeb.BoomLive.handle_event/3"
      assert origin =~ "DemoWeb.BoomLive.handle_event/3"
      refute inspect(error) =~ "hunter2"
      assert frames |> Enum.map(&byte_size/1) |> Enum.sum() < 5_000
      assert byte_size(origin) < 1_000
    end

    defp strict_crash(config) do
      previous = Application.fetch_env(:phoenix_dev_toolbar, :stack_args)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phoenix_dev_toolbar, :stack_args, value)
          :error -> Application.delete_env(:phoenix_dev_toolbar, :stack_args)
        end

        Collector.attach([LiveViewPlugin])
      end)

      Application.put_env(:phoenix_dev_toolbar, :stack_args, config)
      Collector.attach([LiveViewPlugin])
      view = boom_view()
      params = %{"user" => %{"password" => "hunter2", "name" => "ann"}}
      crash(fn -> render_hook(view, "strict", params) end)

      [session] =
        for s <- Store.sessions(), s.kind == :live_view, s.view == DemoWeb.BoomLive, do: s

      session
    end

    defp stored_stack_args(session) do
      session.sid
      |> Store.events()
      |> Enum.find_value(fn %Event{data: data} -> data[:stack_args] end)
    end

    test "default off: nothing stored" do
      session = strict_crash(false)
      assert stored_stack_args(session) == nil
    end

    test "opted in: stored redacted, hidden from agents by default" do
      session = strict_crash(true)

      assert [args | _] = stored_stack_args(session)
      assert args =~ "ann"
      assert args =~ "[REDACTED]"
      refute args =~ "hunter2"

      assert [error] = for(%{source: :live_view} = e <- Report.errors(session.sid), do: e)
      refute Map.has_key?(error, :stack_args)
      refute inspect(Report.summary(session.sid)) =~ "ann"
    end

    test "agents: true puts them in the report" do
      session = strict_crash(agents: true)

      assert [error] = for(%{source: :live_view} = e <- Report.errors(session.sid), do: e)
      assert [args | _] = error.stack_args
      assert args =~ "[REDACTED]"
      refute inspect(error) =~ "hunter2"
    end

    test "a :hide rule keeps the arguments out" do
      session = strict_crash(rules: [{DemoWeb.BoomLive, :hide}])
      assert stored_stack_args(session) == nil
    end
  end
end
