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
end
