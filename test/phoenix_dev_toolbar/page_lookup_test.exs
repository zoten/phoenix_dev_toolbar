defmodule PhoenixDevToolbar.PageLookupTest do
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.ReportFixtures

  alias PhoenixDevToolbar.PageLookup
  alias PhoenixDevToolbar.Store

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
  end

  test "newest/1 is nil when nothing is captured" do
    assert PageLookup.newest() == nil
    assert PageLookup.newest(path: "/nowhere") == nil
  end

  test "newest/1 picks the newest page, by exact path or by prefix" do
    users = session(:request, path: "/users", started_at: 1_800_000_000_000_000)
    user = session(:request, path: "/users/1", started_at: 1_800_000_000_000_010)
    other = session(:request, path: "/posts", started_at: 1_800_000_000_000_020)

    assert PageLookup.newest() == other.sid
    assert PageLookup.newest(path: "/users") == users.sid
    assert PageLookup.newest(path_prefix: "/users") == user.sid
    assert PageLookup.newest(path_prefix: ".*") == nil
  end

  test "a connected mount resolves to its request, live navigation stays itself" do
    root = session(:request, path: "/a", started_at: 1_800_000_000_000_000)
    mount = session(:live_view, path: "/a", parent: root.sid, started_at: 1_800_000_000_000_010)

    assert PageLookup.newest() == root.sid

    nav = session(:live_view, path: "/b", parent: mount.sid, started_at: 1_800_000_000_000_020)
    assert PageLookup.newest() == nav.sid
  end

  test "valid_sid?/1 accepts url safe ids of 1 to 64 characters only" do
    assert PageLookup.valid_sid?("abc-DEF_123")
    assert PageLookup.valid_sid?(String.duplicate("a", 64))
    refute PageLookup.valid_sid?("")
    refute PageLookup.valid_sid?(String.duplicate("a", 65))
    refute PageLookup.valid_sid?("a b")
    refute PageLookup.valid_sid?("a\n")
    refute PageLookup.valid_sid?(nil)
  end
end
