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

defmodule PhoenixDevToolbar.ConfigMcpMaxBytesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import PhoenixDevToolbar.EnvHelpers

  alias PhoenixDevToolbar.Config

  test "max_result_bytes defaults to 60_000 for every shape without it" do
    for value <- [:unset, true, false, [clients: :any], :maybe] do
      case value do
        :unset -> delete_app_env(:mcp)
        other -> put_app_env(:mcp, other)
      end

      assert Config.mcp_max_result_bytes() == 60_000
    end
  end

  test "a positive integer or :infinity is accepted, alone or next to clients" do
    put_app_env(:mcp, max_result_bytes: 1_000)
    assert Config.mcp_max_result_bytes() == 1_000
    assert Config.mcp() == :local
    assert capture_log(&Config.warn_mcp/0) == ""

    put_app_env(:mcp, clients: :any, max_result_bytes: :infinity)
    assert Config.mcp_max_result_bytes() == :infinity
    assert Config.mcp() == :any

    put_app_env(:mcp, clients: ["10.0.0.0/8"], max_result_bytes: 5)
    assert {:list, [{{10, 0, 0, 0}, 8}]} = Config.mcp()
    assert Config.mcp_max_result_bytes() == 5
    assert capture_log(&Config.warn_mcp/0) == ""
  end

  test "a bad value uses the default and warns once at boot" do
    for bad <- [0, -5, "big", 1.5, nil] do
      put_app_env(:mcp, clients: :local, max_result_bytes: bad)
      assert Config.mcp_max_result_bytes() == 60_000
      log = capture_log(&Config.warn_mcp/0)
      assert log =~ "max_result_bytes"
      assert log |> String.split("max_result_bytes") |> length() == 2
    end
  end

  test "duplicate keys are an invalid shape: :local and the boot warning" do
    put_app_env(:mcp, clients: :any, clients: :local)
    assert Config.mcp() == :local
    assert capture_log(&Config.warn_mcp/0) =~ "invalid mcp"

    put_app_env(:mcp, max_result_bytes: 5, max_result_bytes: 7)
    assert Config.mcp_max_result_bytes() == 60_000
    assert capture_log(&Config.warn_mcp/0) =~ "invalid mcp"
  end

  test "an improper list next to max_result_bytes is :local with the default cap" do
    put_app_env(:mcp, [{:max_result_bytes, 5} | :tail])
    assert Config.mcp() == :local
    assert Config.mcp_max_result_bytes() == 60_000
    assert capture_log(&Config.warn_mcp/0) =~ "invalid mcp"
  end

  test "unknown keys keep the invalid shape warning" do
    put_app_env(:mcp, clients: :local, bogus: 1)
    assert Config.mcp() == :local
    assert capture_log(&Config.warn_mcp/0) =~ "invalid mcp"
    put_app_env(:mcp, [])
    assert capture_log(&Config.warn_mcp/0) =~ "invalid mcp"
  end
end
