defmodule PhoenixDevToolbar.EvalTest do
  # The Eval tab (ADR 12): read only and loopback only unless the host says so.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers

  alias PhoenixDevToolbar.EvalRunner
  alias PhoenixDevToolbar.Plugins.Eval
  alias PhoenixDevToolbar.Store

  @endpoint DemoWeb.Endpoint

  defp attach(opts) do
    capture_log(fn -> attach_plugins([{Eval, opts}]) end)
  end

  defp open(conn \\ build_conn()) do
    {_host, sid} = visit("/demo")
    {:ok, panel, _html} = live(conn, "/__pdt/panel?sid=#{sid}")
    panel |> element("#pdt-tab-eval") |> render_click()
    panel
  end

  setup do
    Store.reset()

    on_exit(fn ->
      attach_plugins()
      Store.reset()
    end)
  end

  describe "options" do
    test "safe defaults; each override is validated and warned about" do
      assert Eval.init([]) == {:ok, %{allow: :read_only, clients: :loopback, timeout_ms: 5000}}
      assert {:error, "allow must be" <> _rest} = Eval.init(allow: :yes)
      assert {:error, "clients must be" <> _rest} = Eval.init(clients: :lan)
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

  test "what code prints is capped while it runs" do
    code = ~s|for _ <- 1..500, do: IO.write(String.duplicate("x", 1000)); :done|

    assert {:ok, %{result: ":done", output: output}} = EvalRunner.eval(code, 5000)
    assert byte_size(output) < 9_000
  end

  test "code is stopped on time even when its caller is gone" do
    probe = :"pdt_eval_probe_#{System.unique_integer([:positive])}"
    code = "Process.register(self(), #{inspect(probe)}); Process.sleep(:infinity)"
    caller = spawn(fn -> EvalRunner.eval(code, 100) end)
    evaluator = wait_for_name(probe, 100_000)
    ref = Process.monitor(evaluator)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^ref, :process, ^evaluator, :killed}, 1000
  end

  # The evaluator registers itself as soon as it runs: no message tells when.
  defp wait_for_name(_name, 0), do: flunk("the evaluator never ran")

  defp wait_for_name(name, tries) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> pid
      nil -> :erlang.yield() && wait_for_name(name, tries - 1)
    end
  end

  test "code is capped in size" do
    big = String.duplicate("1", EvalRunner.max_code_bytes() + 1)
    assert {:error, "At most" <> _rest} = EvalRunner.eval(big, 100)
  end
end
