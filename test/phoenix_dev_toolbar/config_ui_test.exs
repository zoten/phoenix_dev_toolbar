defmodule PhoenixDevToolbar.ConfigUiTest do
  # Changes global app env (pill_corner, shortcut): never async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import PhoenixDevToolbar.EnvHelpers

  alias PhoenixDevToolbar.Config

  describe "pill_corner/0" do
    test "is the bottom right corner when unset" do
      delete_app_env(:pill_corner)
      assert Config.pill_corner() == :bottom_right
    end

    test "accepts each corner" do
      for corner <- [:bottom_right, :bottom_left, :top_right, :top_left] do
        put_app_env(:pill_corner, corner)
        assert Config.pill_corner() == corner
      end
    end

    test "falls back to the bottom right corner on anything else, silently" do
      for invalid <- [:middle, "top_left", nil, 1, [:top_left], %{}] do
        put_app_env(:pill_corner, invalid)
        assert capture_log(fn -> assert Config.pill_corner() == :bottom_right end) == ""
      end
    end
  end

  describe "shortcut/0" do
    defp shortcut(value) do
      put_app_env(:shortcut, value)
      Config.shortcut()
    end

    test "is nil when unset" do
      delete_app_env(:shortcut)
      assert Config.shortcut() == nil
    end

    test "keeps the canonical form" do
      assert shortcut("ctrl+shift+d") == "ctrl+shift+d"
      assert shortcut("ctrl+alt+shift+meta+f12") == "ctrl+alt+shift+meta+f12"
      assert shortcut("alt+1") == "alt+1"
    end

    test "ignores case and spaces around the plus" do
      assert shortcut("Ctrl + Shift + D") == "ctrl+shift+d"
      assert shortcut("  CTRL+F5 ") == "ctrl+f5"
    end

    test "accepts the aliases cmd, control and option" do
      assert shortcut("cmd+k") == "meta+k"
      assert shortcut("control+k") == "ctrl+k"
      assert shortcut("option+k") == "alt+k"
    end

    test "orders the modifiers and drops duplicates" do
      assert shortcut("meta+shift+alt+ctrl+k") == "ctrl+alt+shift+meta+k"
      assert shortcut("ctrl+control+k") == "ctrl+k"
    end

    test "is nil without a modifier, with two keys, or with an unknown key" do
      for invalid <- [
            "d",
            "f5",
            "ctrl",
            "ctrl+",
            "+d",
            "ctrl+a+b",
            "ctrl+f13",
            "ctrl+f0",
            "ctrl+enter",
            "ctrl+ab",
            "ctrl++",
            ""
          ] do
        assert shortcut(invalid) == nil, invalid
      end
    end

    test "is nil for anything that is not a binary, never raising" do
      for invalid <- [:"ctrl+d", ["ctrl+d"], 1, nil, %{}, {:ctrl, "d"}, <<255, 43, 100>>] do
        assert shortcut(invalid) == nil
      end
    end
  end

  describe "warn_ui/0" do
    test "is silent when both are valid or unset" do
      delete_app_env(:pill_corner)
      delete_app_env(:shortcut)
      assert capture_log(fn -> assert Config.warn_ui() == :ok end) == ""

      put_app_env(:pill_corner, :top_left)
      put_app_env(:shortcut, "ctrl+shift+d")
      assert capture_log(fn -> Config.warn_ui() end) == ""
    end

    test "warns about an invalid pill_corner and names the fallback" do
      put_app_env(:pill_corner, :middle)
      delete_app_env(:shortcut)
      log = capture_log(fn -> Config.warn_ui() end)
      assert log =~ "invalid pill_corner: :middle"
      assert log =~ "Using :bottom_right"
      refute log =~ "shortcut"
    end

    test "warns about an invalid shortcut and names the fallback" do
      delete_app_env(:pill_corner)
      put_app_env(:shortcut, "d")
      log = capture_log(fn -> Config.warn_ui() end)
      assert log =~ ~s(invalid shortcut: "d")
      assert log =~ "no shortcut"
      refute log =~ "pill_corner"
    end

    test "warns once per invalid value" do
      put_app_env(:pill_corner, 1)
      put_app_env(:shortcut, :oops)
      log = capture_log(fn -> Config.warn_ui() end)
      assert log =~ "pill_corner"
      assert log =~ "shortcut"
    end
  end
end
