defmodule PhoenixDevToolbar.ProcessHelpers do
  @moduledoc false
  # Runs code in a separate, long lived process, as a request or LiveView
  # process would. The process stays alive until the test exits or `stop/1`.

  import ExUnit.Assertions
  import ExUnit.Callbacks

  @spec in_process((-> result)) :: {pid(), result} when result: term()
  def in_process(fun) do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:in_process_done, self(), fun.()})
        receive(do: (:stop -> :ok))
      end)

    on_exit(fn -> send(pid, :stop) end)
    assert_receive {:in_process_done, ^pid, result}
    {pid, result}
  end

  @spec idle_process() :: pid()
  def idle_process do
    {pid, :ok} = in_process(fn -> :ok end)
    pid
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    :ok
  end
end
