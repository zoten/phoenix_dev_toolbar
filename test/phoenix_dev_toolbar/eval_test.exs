defmodule PhoenixDevToolbar.EvalTest do
  # The Eval tab (ADR 12): read only and this machine only unless the host says so.
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.EnvHelpers
  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers

  alias PhoenixDevToolbar.EvalRunner
  alias PhoenixDevToolbar.Panels.Eval, as: Panel
  alias PhoenixDevToolbar.Plugins.Eval

  defp attach(opts) do
    capture_log(fn -> attach_plugins([{Eval, opts}]) end)
  end

  defp open(conn \\ build_conn()), do: open_tab("/demo", "eval", conn: conn)

  setup do
    with_configured_plugins()
  end

  describe "options" do
    test "safe defaults; each override is validated and warned about" do
      assert Eval.init([]) == {:ok, %{allow: :read_only, clients: :local, timeout_ms: 5000}}
      assert {:error, "allow must be" <> _rest} = Eval.init(allow: :yes)
      assert {:error, "clients must be" <> _rest} = Eval.init(clients: :lan)
      assert Eval.init(clients: :loopback) == Eval.init(clients: :local)
      assert {:error, "timeout_ms must be" <> _rest} = Eval.init(timeout_ms: 10)
      assert {:error, "unknown options" <> _rest} = Eval.init(code: "1")

      assert capture_log(fn -> {:ok, _config} = Eval.init(allow: :eval, clients: :any) end) =~
               "anyone who reaches this dev server can run code"

      # clients: only matters for code: no warning when code is off.
      assert capture_log(fn -> {:ok, _config} = Eval.init(clients: :any) end) == ""
    end
  end

  describe "the tab" do
    test "read only by default: queries run, code does not" do
      attach([])
      panel = open()

      refute has_element?(panel, "#pdt-eval-form")
      assert has_element?(panel, "#pdt-eval-read-only")

      panel |> form("#pdt-eval-query-form", %{"query" => "counts"}) |> render_submit()
      _ = render_async(panel)
      assert has_element?(panel, "#pdt-eval-run-0", "processes")

      # A query that is not in the list runs nothing.
      panel |> element("#pdt-eval-query-form") |> render_submit(%{"query" => "pdt_nope"})
      _ = render_async(panel)
      refute has_element?(panel, "#pdt-eval-run-1")
    end

    test "a forged eval event under the default config runs nothing" do
      attach([])
      panel = open()
      pid = :erlang.pid_to_list(self())
      code = "send(:erlang.list_to_pid(~c\"#{pid}\"), :forged_eval_ran)"

      assert has_element?(panel, "#pdt-eval-read-only")
      panel |> with_target("#pdt-eval") |> render_click("eval", %{"code" => code})
      _ = render_async(panel)

      refute_received :forged_eval_ran
      assert has_element?(panel, "#pdt-eval-note")
      refute has_element?(panel, "#pdt-eval-run-0")
    end

    test "an explicit actions: false refuses code even with allow: :eval; unset does not" do
      attach(allow: :eval)

      delete_app_env(:actions)
      assert has_element?(open(), "#pdt-eval-form")

      put_app_env(:actions, false)
      panel = open()
      assert has_element?(panel, "#pdt-eval-disabled", "actions: false")
      refute has_element?(panel, "#pdt-eval-form")

      pid = :erlang.pid_to_list(self())
      code = "send(:erlang.list_to_pid(~c\"#{pid}\"), :forged_eval_ran)"
      panel |> with_target("#pdt-eval") |> render_click("eval", %{"code" => code})
      _ = render_async(panel)
      refute_received :forged_eval_ran
    end

    test "with allow: :eval, code runs: result, output, errors and a timeout" do
      attach(allow: :eval, timeout_ms: 200)
      panel = open()

      run = fn code ->
        capture_log(fn ->
          panel |> form("#pdt-eval-form", %{"code" => code}) |> render_submit()
        end)

        # Longer than the eval timeout (200 ms).
        _ = render_async(panel, 1000)
      end

      run.(~s|IO.puts("hello"); 40 + 2|)
      assert has_element?(panel, "#pdt-eval-run-0 .pdt-eval__result", "42")
      assert has_element?(panel, "#pdt-eval-run-0 .pdt-eval__output", "hello")

      run.(~s|raise "boom"|)
      assert has_element?(panel, "#pdt-eval-run-0 .pdt-error", "boom")

      run.("Process.sleep(:infinity)")
      assert has_element?(panel, "#pdt-eval-run-0 .pdt-error", "stopped")
      assert has_element?(panel, "#pdt-eval-run-2", "42")
    end

    test "a browser off this machine runs no code, unless clients: :any; queries stay open" do
      attach(allow: :eval)

      remote =
        Plug.Test.put_peer_data(build_conn(), %{address: {10, 0, 0, 7}, port: 1, ssl_cert: nil})

      panel = open(remote)

      assert has_element?(panel, "#pdt-eval-off")
      refute has_element?(panel, "#pdt-eval-form")

      panel |> form("#pdt-eval-query-form", %{"query" => "counts"}) |> render_submit()
      _ = render_async(panel)
      assert has_element?(panel, "#pdt-eval-run-0", "processes")

      # A forged eval event from that browser (sent to the tab) runs nothing.
      panel |> with_target("#pdt-eval") |> render_click("eval", %{"code" => "1 + 1"})
      _ = render_async(panel)
      refute has_element?(panel, "#pdt-eval-run-1")

      attach(allow: :eval, clients: :any)
      panel = open(remote)
      assert has_element?(panel, "#pdt-eval-form")
    end
  end

  test "a browser behind a proxy or tunnel is not loopback, even from 127.0.0.1" do
    attach(allow: :eval)
    proxied = Plug.Conn.put_req_header(build_conn(), "x-forwarded-for", "203.0.113.9")
    panel = open(proxied)

    assert has_element?(panel, "#pdt-eval-off")
    refute has_element?(panel, "#pdt-eval-form")
  end

  describe "gate/3" do
    @own [{192, 168, 1, 20}]
    @own_fun &__MODULE__.own/0

    def own, do: @own

    setup do
      delete_app_env(:actions)
      :ok
    end

    test "this machine's own address runs code under :local and :loopback" do
      for clients <- [:local, :loopback] do
        assert Panel.gate({127, 0, 0, 1}, clients, @own_fun) == :ok
        assert Panel.gate({192, 168, 1, 20}, clients, @own_fun) == :ok
      end
    end

    test "a LAN peer and a proxied client (nil) are refused; :any allows" do
      for clients <- [:local, :loopback] do
        assert Panel.gate({192, 168, 1, 99}, clients, @own_fun) == {:error, :not_local}
        assert Panel.gate(nil, clients, @own_fun) == {:error, :not_local}
      end

      assert Panel.gate({192, 168, 1, 99}, :any, @own_fun) == :ok
      assert Panel.gate(nil, :any, @own_fun) == :ok
    end

    test "own addresses are looked up only for a non local peer under :local" do
      test_pid = self()

      spy = fn ->
        send(test_pid, :own_addresses_called)
        @own
      end

      assert Panel.gate({127, 0, 0, 1}, :local, spy) == :ok
      assert Panel.gate({192, 168, 1, 99}, :any, spy) == :ok
      put_app_env(:actions, false)
      assert Panel.gate({192, 168, 1, 99}, :local, spy) == {:error, :disabled}
      refute_received :own_addresses_called

      delete_app_env(:actions)
      assert Panel.gate({192, 168, 1, 99}, :local, spy) == {:error, :not_local}
      assert_received :own_addresses_called
    end

    test "an explicit actions: false refuses everyone" do
      put_app_env(:actions, false)
      assert Panel.gate({127, 0, 0, 1}, :any, @own_fun) == {:error, :disabled}
    end
  end

  test "what code prints is capped while it runs" do
    code = ~s|for _ <- 1..500, do: IO.write(String.duplicate("x", 1000)); :done|

    assert {:ok, %{result: ":done", output: output}} = EvalRunner.eval(code, 5000)
    assert byte_size(output) < 9_000
  end

  test "code is stopped on time even when its caller is gone" do
    # The evaluator reports itself to this test, which is registered for it.
    probe = :"pdt_eval_probe_#{System.unique_integer([:positive])}"
    Process.register(self(), probe)
    code = "send(#{inspect(probe)}, {:evaluator, self()}); Process.sleep(:infinity)"
    caller = start_supervised!({Task, fn -> EvalRunner.eval(code, 100) end})
    assert_receive {:evaluator, evaluator}, 1000
    ref = Process.monitor(evaluator)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^ref, :process, ^evaluator, :killed}, 1000
  end

  test "every read query runs and returns a bounded result" do
    for {id, _label} <- EvalRunner.queries() do
      assert {:ok, %{result: result, error: nil, output: ""}} = EvalRunner.query(id),
             "query #{id} failed"

      assert byte_size(result) in 1..20_000, "query #{id} result is not bounded"
    end
  end

  test "code is capped in size" do
    big = String.duplicate("1", EvalRunner.max_code_bytes() + 1)
    assert {:error, "At most" <> _rest} = EvalRunner.eval(big, 100)
  end
end
