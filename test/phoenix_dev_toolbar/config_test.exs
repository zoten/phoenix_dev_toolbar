defmodule PhoenixDevToolbar.ConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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
    {Plugins.Process, []}
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
             {Plugins.Process, []}
           ]
  end

  test "{:exclude, module} removes a plugin wherever it is listed" do
    assert Config.expand([:defaults, {:exclude, Plugins.LiveView}]) ==
             [{Plugins.Ecto, []}, {Plugins.Request, []}, {Plugins.Process, []}]
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

    test "a value that is not a keyword list keeps every default, with a warning" do
      log = capture_log(fn -> assert Config.limits(:oops, @limit_defaults) == @limit_defaults end)
      assert log =~ "keyword list"
    end
  end
end
