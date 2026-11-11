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

  describe "actions: :local and its alias :loopback" do
    @own [{192, 168, 1, 20}]
    @own_fun &__MODULE__.own/0

    def own, do: @own

    for value <- [:local, :loopback] do
      test "actions: #{inspect(value)} lets this machine act: loopback and own addresses" do
        put_app_env(:actions, unquote(value))

        assert ClientPolicy.mode() == :local
        assert ClientPolicy.check_actions({127, 0, 0, 1}, @own_fun) == :ok
        assert ClientPolicy.check_actions({192, 168, 1, 20}, @own_fun) == :ok
      end

      test "actions: #{inspect(value)} refuses a LAN peer and a proxied client, silently" do
        put_app_env(:actions, unquote(value))

        assert ClientPolicy.check_actions({192, 168, 1, 99}, @own_fun) == {:error, :not_local}
        assert ClientPolicy.check_actions(nil, @own_fun) == {:error, :not_local}
        assert capture_log(fn -> ClientPolicy.warn_config() end) == ""
      end
    end
  end

  test "own addresses are not looked up for a loopback peer, nor under :any" do
    test_pid = self()

    spy = fn ->
      send(test_pid, :own_addresses_called)
      []
    end

    put_app_env(:actions, :local)
    assert ClientPolicy.check_actions({127, 0, 0, 1}, spy) == :ok
    put_app_env(:actions, :any)
    assert ClientPolicy.check_actions({203, 0, 113, 9}, spy) == :ok
    refute_received :own_addresses_called
  end

  test "check_actions_for/1 uses a verdict computed earlier" do
    put_app_env(:actions, :local)
    assert ClientPolicy.check_actions_for(true) == :ok
    assert ClientPolicy.check_actions_for(false) == {:error, :not_local}
    put_app_env(:actions, false)
    assert ClientPolicy.check_actions_for(true) == {:error, :disabled}
  end

  test "actions: :any lets every client act, and warns" do
    put_app_env(:actions, :any)

    assert ClientPolicy.check_actions({10, 0, 0, 2}, &__MODULE__.own/0) == :ok
    assert ClientPolicy.check_actions(nil, &__MODULE__.own/0) == :ok
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
