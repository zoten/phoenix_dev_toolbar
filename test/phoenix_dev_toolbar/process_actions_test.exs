defmodule PhoenixDevToolbar.ProcessActionsTest do
  # Changes the application env (`actions:`) and uses the app's Suspender.
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.EnvHelpers
  import ExUnit.CaptureLog
  import PhoenixDevToolbar.ProcessHelpers

  alias PhoenixDevToolbar.ProcessActions

  @local %{panel: nil, client: {127, 0, 0, 1}}

  setup do
    put_app_env(:actions, :local)

    {:ok, context: %{@local | panel: self()}}
  end

  test "a client off this machine may not act, and is told how to allow it", %{context: context} do
    pid = idle_process()
    ref = Process.monitor(pid)
    remote = %{context | client: {192, 168, 1, 20}}

    assert {:error, message} = ProcessActions.kill(pid, "kill", remote)
    assert message =~ "actions: :any"
    assert {:error, _message} = ProcessActions.peek(pid, remote)
    refute_received {:DOWN, ^ref, :process, ^pid, _reason}

    put_app_env(:actions, false)
    assert {:error, "Actions are off" <> _rest} = ProcessActions.allowed(pid, context)
  end

  test "with actions unset nobody acts, and the message names the option", %{context: context} do
    delete_app_env(:actions)
    pid = idle_process()
    ref = Process.monitor(pid)

    assert {:error, message} = ProcessActions.kill(pid, "kill", context)
    assert message =~ "actions: :local"
    assert {:error, _message} = ProcessActions.peek(pid, context)
    refute_received {:DOWN, ^ref, :process, ^pid, _reason}
  end

  test "a protected process is never killed", %{context: context} do
    code_server = Process.whereis(:code_server)

    assert {:error, "Protected: " <> _why} = ProcessActions.kill(code_server, "kill", context)
    assert {:error, "Protected: " <> _why} = ProcessActions.kill(self(), "kill", context)
  end

  test "kill with a crash exits like a crash, and is logged", %{context: context} do
    pid = idle_process()
    ref = Process.monitor(pid)

    log = capture_log(fn -> assert ProcessActions.kill(pid, "crash", context) == :ok end)

    assert_receive {:DOWN, ^ref, :process, ^pid, {%RuntimeError{}, []}}
    assert log =~ "killed #{inspect(pid)}"
  end

  test "an unknown reason kills nothing", %{context: context} do
    pid = idle_process()
    ref = Process.monitor(pid)

    assert ProcessActions.kill(pid, "nuke", context) == {:error, "Unknown kill reason."}
    refute_received {:DOWN, ^ref, :process, ^pid, _reason}
  end

  test "suspend and resume, logged", %{context: context} do
    pid = idle_process()

    log = capture_log(fn -> assert ProcessActions.suspend(pid, context) == :ok end)
    assert log =~ "suspended #{inspect(pid)}"
    assert Process.info(pid, :status) == {:status, :suspended}

    assert ProcessActions.resume(pid) == :ok
    refute Process.info(pid, :status) == {:status, :suspended}
  end

  test "a suspended process can still be killed", %{context: context} do
    pid = idle_process()
    ref = Process.monitor(pid)
    capture_log(fn -> :ok = ProcessActions.suspend(pid, context) end)

    capture_log(fn -> assert ProcessActions.kill(pid, "kill", context) == :ok end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  test "peek shows the first messages, redacted, under a queue limit", %{context: context} do
    pid = idle_process()
    send(pid, {:login, %{user: "ada", password: "hunter2"}})
    send(pid, :second)

    assert {:ok, [first, ":second"], 2} = ProcessActions.peek(pid, context)
    assert first =~ "[REDACTED]"
    refute first =~ "hunter2"

    for n <- 1..100, do: send(pid, {:n, n})
    assert {:error, "102 messages queued" <> _rest} = ProcessActions.peek(pid, context)
  end
end
