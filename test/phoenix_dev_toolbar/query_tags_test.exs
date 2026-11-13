defmodule PhoenixDevToolbar.QueryTagsTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.QueryTags

  @app_frames ["lib/demo/users.ex:9: DemoWeb.Users.list/0"]

  test "a query is tagged with its source table" do
    assert QueryTags.tags(%{source: "users", stacktrace: @app_frames}) == ["source:users"]
  end

  test "a query without a source is tagged no source" do
    assert QueryTags.tags(%{source: nil, sql: "BEGIN"}) == ["flag:no_source"]
  end

  test "framework and task queries carry their flags" do
    data = %{
      source: "schema_migrations",
      sql: "SELECT version FROM schema_migrations",
      caller?: true
    }

    assert QueryTags.tags(data) == ["source:schema_migrations", "flag:framework", "flag:task"]
  end

  test "a table named like a flag never collides with it" do
    assert QueryTags.tags(%{source: "framework", stacktrace: @app_frames}) == ["source:framework"]
  end

  test "a query is hidden when any of its tags is off" do
    data = %{source: "users", caller?: true, stacktrace: @app_frames}

    assert QueryTags.visible?(data, MapSet.new())
    assert QueryTags.visible?(data, MapSet.new(["source:posts"]))
    refute QueryTags.visible?(data, MapSet.new(["flag:task"]))
  end

  test "ordered lists sources by name, then flags, capped" do
    counts = %{"flag:framework" => 1, "source:posts" => 2, "source:users" => 3, "source:a" => 1}

    assert QueryTags.ordered(counts, 2) ==
             {[
                {"source:a", "a", 1},
                {"source:posts", "posts", 2},
                {"flag:framework", "framework", 1}
              ], 1}
  end
end
