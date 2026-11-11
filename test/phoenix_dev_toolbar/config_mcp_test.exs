defmodule PhoenixDevToolbar.ConfigMcpTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import PhoenixDevToolbar.EnvHelpers

  alias PhoenixDevToolbar.Config

  test "mcp? is on unless set to false" do
    delete_app_env(:mcp)
    assert Config.mcp?()
    put_app_env(:mcp, false)
    refute Config.mcp?()
  end

  test "an invalid mcp value counts as on and is logged at boot" do
    put_app_env(:mcp, :maybe)
    assert Config.mcp?()
    assert capture_log(&Config.warn_mcp/0) =~ "invalid mcp"

    put_app_env(:mcp, true)
    assert capture_log(&Config.warn_mcp/0) == ""
  end

  test "mcp/0 maps every accepted shape" do
    delete_app_env(:mcp)
    assert Config.mcp() == :local
    put_app_env(:mcp, true)
    assert Config.mcp() == :local
    put_app_env(:mcp, false)
    assert Config.mcp() == :off
    put_app_env(:mcp, clients: :local)
    assert Config.mcp() == :local
    put_app_env(:mcp, clients: :any)
    assert Config.mcp() == :any
    put_app_env(:mcp, :maybe)
    assert Config.mcp() == :local
    put_app_env(:mcp, clients: "10.0.0.0/8")
    assert Config.mcp() == :local
  end

  test "a clients list keeps the valid entries and ignores the rest" do
    put_app_env(:mcp, clients: ["10.0.0.0/8", "nope", 5, "fd00::/8"])
    assert {:list, [{{10, 0, 0, 0}, 8}, {{0xFD00, 0, 0, 0, 0, 0, 0, 0}, 8}]} = Config.mcp()
    assert Config.mcp?()
  end

  test "boot warnings: :any, invalid entries, quiet for valid shapes" do
    put_app_env(:mcp, clients: :any)
    assert capture_log(&Config.warn_mcp/0) =~ "anyone who reaches this dev server"

    put_app_env(:mcp, clients: ["10.0.0.0/8", "bogus", "10.0.0.0/33"])
    log = capture_log(&Config.warn_mcp/0)
    assert log =~ "bogus"
    assert log =~ "10.0.0.0/33"
    refute log =~ "\"10.0.0.0/8\""

    for ok <- [[clients: :local], [clients: ["10.0.0.0/8"]], false] do
      put_app_env(:mcp, ok)
      assert capture_log(&Config.warn_mcp/0) == ""
    end

    put_app_env(:mcp, clients: 5)
    assert capture_log(&Config.warn_mcp/0) =~ "invalid mcp"
  end

  test "a non-UTF-8 entry is ignored and logged, never raised" do
    put_app_env(:mcp, clients: ["10.0.0.0/8", <<255>>])
    assert {:list, [{{10, 0, 0, 0}, 8}]} = Config.mcp()
    assert capture_log(&Config.warn_mcp/0) =~ "invalid mcp clients"
  end

  test "an improper clients list is :local with one boot warning, never raised" do
    put_app_env(:mcp, clients: ["10.0.0.0/8" | "tail"])
    assert Config.mcp() == :local
    assert Config.mcp?()
    assert capture_log(&Config.warn_mcp/0) =~ "invalid mcp"
  end
end
