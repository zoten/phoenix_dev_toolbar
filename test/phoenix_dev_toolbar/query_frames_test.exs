defmodule PhoenixDevToolbar.QueryFramesTest do
  # The caller and noise readers of a query's stored stacktrace (ADR 08).
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.QueryFrames

  @patterns QueryFrames.default_patterns()

  # A permission check several frames below the LiveView that ran it.
  @policy_stack [
    "lib/demo/events/governance.ex:270: Demo.Events.Governance.admin_for_event?/2",
    "lib/demo/events/event_team.ex:149: Demo.Events.EventTeam.can?/3",
    "lib/demo/policy/helpers.ex:25: Demo.Policy.Helpers.check/2",
    "lib/demo/policy.ex:555: Demo.Policy.dispatch/3",
    "lib/demo_web/live/weigh_in_live.ex:63: DemoWeb.WeighInLive.mount/3",
    "lib/phoenix/live_view/utils.ex:350: Phoenix.LiveView.Utils.maybe_call_mount!/3"
  ]

  describe "caller/2" do
    test "the first frame of a Web module, past the Repo call site" do
      assert QueryFrames.caller(@policy_stack, @patterns) ==
               "lib/demo_web/live/weigh_in_live.ex:63: DemoWeb.WeighInLive.mount/3"
    end

    test "a LiveView callback or an on_mount hook outside a Web namespace" do
      on_mount = [
        "lib/demo/accounts.ex:9: Demo.Accounts.get_user!/1",
        "lib/demo/auth.ex:30: Demo.Auth.on_mount/4"
      ]

      assert QueryFrames.caller(on_mount, @patterns) ==
               "lib/demo/auth.ex:30: Demo.Auth.on_mount/4"

      anonymous = [
        "lib/demo/a.ex:1: Demo.A.f/0",
        "lib/demo/b.ex:2: anonymous fn/1 in Demo.Page.handle_event/3"
      ]

      assert QueryFrames.caller(anonymous, @patterns) ==
               "lib/demo/b.ex:2: anonymous fn/1 in Demo.Page.handle_event/3"
    end

    test "never a framework frame, nor a context function that shares a callback name" do
      stack = [
        "lib/demo/posts.ex:4: Demo.Posts.update/2",
        "lib/demo/posts.ex:9: Demo.Posts.render/1",
        "lib/phoenix/live_view/channel.ex:1: Phoenix.LiveView.Channel.mount/3"
      ]

      # Falls back to the frame after the origin.
      assert QueryFrames.caller(stack, @patterns) == "lib/demo/posts.ex:9: Demo.Posts.render/1"
    end

    test "the origin itself when it is web code; nil without a stacktrace" do
      assert QueryFrames.caller(["lib/x.ex:1: DemoWeb.PageLive.load/1"], @patterns) ==
               "lib/x.ex:1: DemoWeb.PageLive.load/1"

      assert QueryFrames.caller(["lib/x.ex:1: Demo.X.f/0"], @patterns) == nil
      assert QueryFrames.caller([], @patterns) == nil
    end

    test "caller_modules: regexes or module name prefixes replace the defaults" do
      assert QueryFrames.caller(@policy_stack, ["Demo.Policy."]) ==
               "lib/demo/policy/helpers.ex:25: Demo.Policy.Helpers.check/2"

      assert QueryFrames.caller(@policy_stack, [~r/EventTeam\z/]) ==
               "lib/demo/events/event_team.ex:149: Demo.Events.EventTeam.can?/3"
    end
  end

  describe "noise/1" do
    test "CheckRepoStatus queries, by frame or by schema_migrations SQL" do
      assert QueryFrames.noise(%{
               sql: ~s(CREATE TABLE IF NOT EXISTS "schema_migrations" ...),
               stacktrace: []
             }) == "check_repo_status"

      assert QueryFrames.noise(%{
               sql: ~s(SELECT s0."version" FROM "other" AS s0),
               stacktrace: [
                 "lib/phoenix_ecto/check_repo_status.ex:1: Phoenix.Ecto.CheckRepoStatus.call/2"
               ]
             }) == "check_repo_status"
    end

    test "framework when no frame is the host's; nil for host queries or no stacktrace" do
      assert QueryFrames.noise(%{
               sql: "SELECT 1",
               stacktrace: [
                 "lib/plug/x.ex:1: Plug.X.call/2",
                 "gen_server.erl:1: :gen_server.call/3"
               ]
             }) == "framework"

      assert QueryFrames.noise(%{sql: "SELECT 1", stacktrace: @policy_stack}) == nil
      assert QueryFrames.noise(%{sql: "SELECT 1", stacktrace: []}) == nil
    end
  end
end
