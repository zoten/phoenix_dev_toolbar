defmodule PhoenixDevToolbar.SessionTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.Session

  doctest Session

  test "new/2 keeps only known attributes and generates distinct sids" do
    a = Session.new(:live_view, owner: self(), path: "/users", unknown: :ignored)
    b = Session.new(:request)

    assert %Session{kind: :live_view, owner: owner, path: "/users"} = a
    assert owner == self()
    assert a.sid != b.sid
  end
end
