defmodule PhoenixDevToolbar.ProcessInfoDepthTest do
  # Raises the VM wide :backtrace_depth: sync, so no async test captures a
  # deeper stacktrace meanwhile.
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.ProcessHelpers

  alias PhoenixDevToolbar.ProcessInfo

  test "stacktrace/1 stops at 20 frames of a deeper stack" do
    # A VM wide flag (returns the previous value), restored on exit.
    depth = :erlang.system_flag(:backtrace_depth, 40)
    on_exit(fn -> :erlang.system_flag(:backtrace_depth, depth) end)

    test = self()
    pid = spawn(fn -> wait_deep(30, test) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:deep, ^pid}
    wait_until(fn -> Process.info(pid, :status) == {:status, :waiting} end)

    assert {:current_stacktrace, raw} = Process.info(pid, :current_stacktrace)
    assert length(raw) > 20

    frames = ProcessInfo.stacktrace(pid)
    assert length(frames) == 20
    assert Enum.all?(frames, &(&1 =~ "wait_deep"))
    assert Enum.any?(frames, &(&1 =~ "wait_deeper"))
  end

  # Non tail recursive, so every level is a frame (two functions alternate:
  # the VM collapses repeats of one frame); the innermost one waits.
  def wait_deep(0, parent) do
    send(parent, {:deep, self()})
    receive(do: (:never -> :ok))
  end

  def wait_deep(n, parent), do: {wait_deeper(n - 1, parent), n}

  def wait_deeper(0, parent), do: wait_deep(0, parent)
  def wait_deeper(n, parent), do: {wait_deep(n - 1, parent), n}
end
