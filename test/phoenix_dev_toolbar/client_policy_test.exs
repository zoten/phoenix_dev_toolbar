defmodule PhoenixDevToolbar.ClientPolicyTest do
  # Changes the application env.
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.EnvHelpers
  import ExUnit.CaptureLog

  alias PhoenixDevToolbar.ClientPolicy

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

  test "by default nobody may act, and the default does not warn" do
    delete_app_env(:actions)

    assert ClientPolicy.mode() == false
    assert ClientPolicy.check_actions({127, 0, 0, 1}) == {:error, :disabled}
    refute ClientPolicy.explicitly_off?()
    assert capture_log(fn -> ClientPolicy.warn_config() end) == ""
  end

  test "actions: :loopback lets only loopback clients act" do
    put_app_env(:actions, :loopback)

    assert ClientPolicy.check_actions({127, 0, 0, 1}) == :ok
    assert ClientPolicy.check_actions({10, 0, 0, 2}) == {:error, :not_loopback}
    assert ClientPolicy.check_actions(nil) == {:error, :not_loopback}
  end

  test "actions: :any lets every client act, and warns" do
    put_app_env(:actions, :any)

    assert ClientPolicy.check_actions({10, 0, 0, 2}) == :ok
    assert capture_log(fn -> ClientPolicy.warn_config() end) =~ "actions: :any"
  end

  test "actions: false lets nobody act" do
    put_app_env(:actions, false)

    assert ClientPolicy.check_actions({127, 0, 0, 1}) == {:error, :disabled}
    assert ClientPolicy.explicitly_off?()
  end

  test "an invalid value counts as off, and warns" do
    put_app_env(:actions, :everyone)

    assert ClientPolicy.mode() == false
    assert ClientPolicy.check_actions({127, 0, 0, 1}) == {:error, :disabled}
    refute ClientPolicy.explicitly_off?()
    assert capture_log(fn -> ClientPolicy.warn_config() end) =~ "invalid actions"
  end
end
