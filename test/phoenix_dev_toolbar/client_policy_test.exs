defmodule PhoenixDevToolbar.ClientPolicyTest do
  # Changes the application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixDevToolbar.ClientPolicy

  setup do
    previous = Application.fetch_env(:phoenix_dev_toolbar, :actions)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_dev_toolbar, :actions, value)
        :error -> Application.delete_env(:phoenix_dev_toolbar, :actions)
      end
    end)
  end

  test "loopback addresses" do
    assert ClientPolicy.loopback?({127, 0, 0, 1})
    assert ClientPolicy.loopback?({127, 1, 2, 3})
    assert ClientPolicy.loopback?({0, 0, 0, 0, 0, 0, 0, 1})
    assert ClientPolicy.loopback?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})

    refute ClientPolicy.loopback?({192, 168, 1, 10})
    refute ClientPolicy.loopback?({172, 17, 0, 1})
    refute ClientPolicy.loopback?({0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0001})
    refute ClientPolicy.loopback?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
    refute ClientPolicy.loopback?(nil)
  end

  test "by default only loopback clients may act" do
    Application.delete_env(:phoenix_dev_toolbar, :actions)

    assert ClientPolicy.check_actions({127, 0, 0, 1}) == :ok
    assert ClientPolicy.check_actions({10, 0, 0, 2}) == {:error, :not_loopback}
    assert ClientPolicy.check_actions(nil) == {:error, :not_loopback}
  end

  test "actions: :any lets every client act, and warns" do
    Application.put_env(:phoenix_dev_toolbar, :actions, :any)

    assert ClientPolicy.check_actions({10, 0, 0, 2}) == :ok
    assert capture_log(fn -> ClientPolicy.warn_config() end) =~ "actions: :any"
  end

  test "actions: false lets nobody act" do
    Application.put_env(:phoenix_dev_toolbar, :actions, false)

    assert ClientPolicy.check_actions({127, 0, 0, 1}) == {:error, :disabled}
  end

  test "an invalid value counts as :loopback, and warns" do
    Application.put_env(:phoenix_dev_toolbar, :actions, :everyone)

    assert ClientPolicy.mode() == :loopback
    assert ClientPolicy.check_actions({10, 0, 0, 2}) == {:error, :not_loopback}
    assert capture_log(fn -> ClientPolicy.warn_config() end) =~ "invalid actions"
  end
end
