defmodule PhoenixDevToolbar.ConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import PhoenixDevToolbar.EnvHelpers

  alias PhoenixDevToolbar.Config
  alias PhoenixDevToolbar.Plugins
  alias PhoenixDevToolbar.TestPlugins.AtomName
  alias PhoenixDevToolbar.TestPlugins.BadPanel
  alias PhoenixDevToolbar.TestPlugins.Echo
  alias PhoenixDevToolbar.TestPlugins.HalfSummary
  alias PhoenixDevToolbar.TestPlugins.NilId
  alias PhoenixDevToolbar.TestPlugins.SameId
  alias PhoenixDevToolbar.TestPlugins.ThrowingId

  @defaults [
    {Plugins.Ecto, []},
    {Plugins.Request, []},
    {Plugins.LiveView, []},
    {Plugins.Process, []},
    {Plugins.System, []}
  ]

  test ":defaults expands to the built-ins, in place" do
    assert Config.expand([:defaults]) == @defaults
    assert Config.expand([Echo, :defaults]) == [{Echo, []} | @defaults]
  end

  test "a built-in listed with options overrides :defaults, keeping its position" do
    assert Config.expand([:defaults, {Plugins.Ecto, repos: [Demo.Repo]}]) == [
             {Plugins.Ecto, repos: [Demo.Repo]},
             {Plugins.Request, []},
             {Plugins.LiveView, []},
             {Plugins.Process, []},
             {Plugins.System, []}
           ]
  end

  test "{:exclude, module} removes a plugin wherever it is listed" do
    assert Config.expand([:defaults, {:exclude, Plugins.LiveView}]) ==
             [
               {Plugins.Ecto, []},
               {Plugins.Request, []},
               {Plugins.Process, []},
               {Plugins.System, []}
             ]
  end

  test "invalid entries are logged and skipped, never raised" do
    log =
      capture_log(fn ->
        assert Config.expand([
                 "nope",
                 {Echo, :not_a_list},
                 Missing.Plugin,
                 DemoWeb.HelloPlug,
                 Echo,
                 SameId
               ]) == [{Echo, []}]
      end)

    assert log =~ ~s(ignoring plugin entry "nope")
    assert log =~ "ignoring plugin Missing.Plugin: module not available"
    assert log =~ "DemoWeb.HelloPlug: it does not implement"
    assert log =~ "SameId: id :echo is taken by PhoenixDevToolbar.TestPlugins.Echo"
  end

  test "a plugin whose id/0 throws is skipped, never crashes the boot" do
    log = capture_log(fn -> assert Config.expand([ThrowingId, Echo]) == [{Echo, []}] end)
    assert log =~ "ignoring plugin PhoenixDevToolbar.TestPlugins.ThrowingId: ** (throw) :nope"
  end

  test "a nil id or a name that is not a string is skipped" do
    log = capture_log(fn -> assert Config.expand([NilId, AtomName, Echo]) == [{Echo, []}] end)

    assert log =~ "NilId: id/0 must return an atom"
    assert log =~ "AtomName: name/0 must return a string"
  end

  test "{:exclude, _} needs a module, and excludes an explicitly listed one too" do
    log =
      capture_log(fn ->
        assert Config.expand([Echo, {:exclude, [Echo]}]) == [{Echo, []}]
        assert Config.expand([Echo, {:exclude, Echo}]) == []
      end)

    assert log =~ "expected {:exclude, Module}"
  end

  test "a half implemented summary or a panel that is not a Panel is skipped" do
    log =
      capture_log(fn -> assert Config.expand([HalfSummary, BadPanel, Echo]) == [{Echo, []}] end)

    assert log =~ "HalfSummary: define all of summary_init/1, summary_add/2, badges/1 or none"
    assert log =~ "BadPanel: panel/0 must return a module that uses PhoenixDevToolbar.Panel"
  end

  test "a value that is not a list falls back to :defaults" do
    log = capture_log(fn -> assert Config.expand(:oops) == @defaults end)
    assert log =~ "must be a list"
  end

  describe "limits/2" do
    @limit_defaults %{max_sessions: 50, ttl_ms: 600_000}

    test "valid overrides replace the defaults" do
      assert Config.limits([max_sessions: 10, ttl_ms: 0], @limit_defaults) ==
               %{max_sessions: 10, ttl_ms: 0}
    end

    test "an invalid value keeps that key's default, with a warning" do
      log =
        capture_log(fn ->
          assert Config.limits([max_sessions: :infinity, ttl_ms: -1], @limit_defaults) ==
                   @limit_defaults
        end)

      assert log =~ "max_sessions"
      assert log =~ "ttl_ms"
    end

    test "unknown keys are ignored, with a warning" do
      log =
        capture_log(fn ->
          assert Config.limits([max_sesions: 10], @limit_defaults) == @limit_defaults
        end)

      assert log =~ "max_sesions"
    end

    test "down_grace_ms is gone: an old config logs it and keeps booting" do
      defaults = PhoenixDevToolbar.Store.default_limits()

      log =
        capture_log(fn -> assert Config.limits([down_grace_ms: 0], defaults) == defaults end)

      assert log =~ "down_grace_ms"
    end

    test "a value that is not a keyword list keeps every default, with a warning" do
      log = capture_log(fn -> assert Config.limits(:oops, @limit_defaults) == @limit_defaults end)
      assert log =~ "keyword list"
    end
  end

  describe "allowed_origins/1" do
    test "keeps origins the browser can send, defaults ports filled in" do
      assert Config.allowed_origins(["https://Abc.Tunnel.example", "http://box.lan:8080/"]) ==
               ["https://Abc.Tunnel.example", "http://box.lan:8080/"]

      assert Config.origin("https://Abc.Tunnel.example") ==
               {:ok, {"https", "abc.tunnel.example", 443}}

      assert Config.origin("http://box.lan:8080/") == {:ok, {"http", "box.lan", 8080}}
    end

    test "drops what can never match an Origin header, one warning per entry" do
      dropped = [
        "abc.tunnel.example",
        "abc.tunnel.example:443",
        "https://*.tunnel.example",
        "https://abc.tunnel.example/app",
        "https://abc.tunnel.example?x=1",
        "https://user@abc.tunnel.example",
        "ftp://abc.tunnel.example",
        "",
        :atom
      ]

      log = capture_log(fn -> assert Config.allowed_origins(dropped) == [] end)

      for entry <- dropped, do: assert(log =~ inspect(entry), inspect(entry))
      assert log =~ "wildcards"
    end

    test "a single origin is wrapped, nothing configured is an empty list" do
      assert Config.allowed_origins("https://abc.tunnel.example") ==
               ["https://abc.tunnel.example"]

      assert Config.allowed_origins(nil) == []
    end
  end

  describe "stack_args/1" do
    test "off unless opted in" do
      assert Config.stack_args(nil) == nil
      assert Config.stack_args(false) == nil
    end

    test "true means the defaults" do
      assert Config.stack_args(true) == %{
               bytes: 512,
               redact: [],
               rules: %{crypto: :hide},
               agents: false
             }
    end

    test "valid options are kept, keys lowered" do
      assert Config.stack_args(
               bytes: 1024,
               redact: ["Card_Number", :pin],
               rules: [{Mod, :hide}, {{Mod, :f}, ["PIN"]}, {{Mod, :f, 2}, :hide}],
               agents: true
             ) == %{
               bytes: 1024,
               redact: ["card_number", "pin"],
               rules: %{
                 :crypto => :hide,
                 Mod => :hide,
                 {Mod, :f} => ["pin"],
                 {Mod, :f, 2} => :hide
               },
               agents: true
             }
    end

    test "invalid entries warn and fall back, never raise" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Config.stack_args(
                   bytes: 10,
                   redact: ["ok", 1],
                   rules: [
                     {"Mod", :hide},
                     {Mod, :nope},
                     {{Mod, :f, -1}, :hide},
                     :junk,
                     {Mod, [1]}
                   ],
                   agents: :yes
                 ) == %{bytes: 512, redact: ["ok"], rules: %{crypto: :hide}, agents: false}

          assert Config.stack_args("yes") == nil
          assert Config.stack_args(bytes: 9000).bytes == 512
          assert Config.stack_args(rules: :x).rules == %{crypto: :hide}
        end)

      assert log =~ "bytes"
      assert log =~ "rule"
      assert log =~ "agents"
    end

    test "improper lists warn and fall back, never raise" do
      log =
        capture_log(fn ->
          assert Config.stack_args(redact: ["a" | "b"]).redact == []
          assert Config.stack_args(rules: [{Mod, :hide} | :x]).rules == %{crypto: :hide}
          assert Config.stack_args(rules: [{Mod, ["a" | "b"]}]).rules == %{crypto: :hide}
        end)

      assert log =~ "proper list"
      assert log =~ "rule"
    end

    test "empty keys are dropped with a warning, they would match every key" do
      log =
        capture_log(fn ->
          assert Config.stack_args(redact: ["", "ok", :""]).redact == ["ok"]
          assert Config.stack_args(rules: [{Mod, [""]}]).rules == %{crypto: :hide}
        end)

      assert log =~ "ignoring"
    end

    test ":crypto is hidden unless the developer writes a rule for it" do
      assert Config.stack_args(true).rules == %{crypto: :hide}
      assert Config.stack_args(rules: [{:crypto, ["key"]}]).rules == %{crypto: ["key"]}
    end
  end

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
