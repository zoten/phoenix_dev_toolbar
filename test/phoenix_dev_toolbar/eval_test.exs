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

      assert capture_log(fn -> {:ok, _config} = Eval.init(clients: :any) end) =~ "any browser"
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

    test "a browser off this machine is refused, unless clients: :any" do
      attach(allow: :eval)

      remote =
        Plug.Test.put_peer_data(build_conn(), %{address: {10, 0, 0, 7}, port: 1, ssl_cert: nil})

      panel = open(remote)

      assert has_element?(panel, "#pdt-eval-off")
      refute has_element?(panel, "#pdt-eval-form")
      refute has_element?(panel, "#pdt-eval-query-form")

      attach(allow: :eval, clients: :any)
      panel = open(remote)
      assert has_element?(panel, "#pdt-eval-form")
    end
  end

  test "code is capped in size" do
    big = String.duplicate("1", EvalRunner.max_code_bytes() + 1)
    assert {:error, "At most" <> _rest} = EvalRunner.eval(big, 100)
  end
end
