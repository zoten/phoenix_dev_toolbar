defmodule PhoenixDevToolbar.ProtectedTest do
  use ExUnit.Case, async: true

  import PhoenixDevToolbar.ProcessHelpers

  alias PhoenixDevToolbar.Protected

  defp context(extra \\ %{}), do: Map.merge(%{panel: self()}, extra)

  test "a host process may be acted on" do
    agent = start_supervised!({Agent, fn -> :ok end})

    assert Protected.check(agent, context()) == :ok
    assert Protected.check(idle_process(), context()) == :ok
  end

  test "the panel and its connection are protected" do
    transport = idle_process()

    assert {:error, _why} = Protected.check(self(), context())
    assert {:error, _why} = Protected.check(transport, context(%{transport: transport}))
  end

  test "the host endpoint is protected" do
    endpoint =
      start_supervised!(%{
        id: :endpoint,
        start: {Agent, :start_link, [fn -> :ok end, [name: ProtectedTestEndpoint]]}
      })

    assert {:error, _why} = Protected.check(endpoint, context(%{endpoint: ProtectedTestEndpoint}))
    assert Protected.check(endpoint, context(%{endpoint: nil})) == :ok
  end

  test "the toolbar's own processes are protected" do
    assert {:error, _why} = Protected.check(Process.whereis(PhoenixDevToolbar.Store), context())
  end

  test "core OTP processes are protected, by name or by application" do
    assert {:error, _why} = Protected.check(Process.whereis(:code_server), context())
    assert {:error, _why} = Protected.check(Process.whereis(:application_controller), context())
    assert {:error, _why} = Protected.check(Process.whereis(:kernel_safe_sup), context())
  end

  test "application masters are protected" do
    master = :application_controller.get_master(:phoenix_dev_toolbar)

    assert {:error, "it is an application master"} = Protected.check(master, context())
  end

  test "an exited process may be acted on: nothing to protect" do
    pid = idle_process()
    stop(pid)

    assert Protected.check(pid, context()) == :ok
  end

  test "another node's process is refused" do
    assert {:error, "it runs on another node"} = Protected.check(remote_pid(), context())
  end

  # A pid of another node, decoded from its external term format (NEW_PID_EXT):
  # no distribution needed.
  defp remote_pid do
    node = "pdt_elsewhere@nohost"

    Plug.Crypto.non_executable_binary_to_term(
      <<131, 88, 119, byte_size(node), node::binary, 1::32, 0::32, 1::32>>
    )
  end
end
