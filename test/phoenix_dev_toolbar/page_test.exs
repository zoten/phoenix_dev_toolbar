defmodule PhoenixDevToolbar.PageTest do
  # initial/1 reads the node global Store.
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.ProcessHelpers

  alias PhoenixDevToolbar.Page
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  setup do
    Store.reset()
    on_exit(&Store.reset/0)

    request = Store.new_session(%{Session.new(:request) | started_at: 1})
    %{root: request.sid, tab: idle_process()}
  end

  defp live(parent, transport, started_at) do
    session = %{
      Session.new(:live_view, parent: parent, owner: idle_process(), transport: transport)
      | started_at: started_at
    }

    Store.new_session(session)
  end

  describe "initial/1" do
    test "shows only the request before its LiveView connects", %{root: root} do
      assert %Page{root: ^root, sids: [^root]} = Page.initial(root)
    end

    test "catches up with navigation that happened before the panel opened",
         %{root: root, tab: tab} do
      first = live(root, tab, 2)
      second = live(first.sid, tab, 3)
      _duplicated_tab = live(second.sid, idle_process(), 4)

      assert %Page{sids: [sid], transport: ^tab} = Page.initial(root)
      assert sid == second.sid
    end

    test "is empty when the request expired", %{root: root} do
      Store.put_limits(ttl_ms: 0)
      Store.sweep(System.system_time(:microsecond) + 1_000_000)

      assert %Page{sids: []} = Page.initial(root)
    end
  end

  describe "follow/2" do
    # The panel opened before the LiveView connected.
    setup %{root: root, tab: tab} do
      before_connect = Page.initial(root)
      first = live(root, tab, 2)
      {:connected, page} = Page.follow(before_connect, first)
      %{page: page, first: first}
    end

    test "adds the first LiveView next to the request", %{page: page, root: root, first: first} do
      assert page.sids == [root, first.sid]
    end

    test "replaces the page on navigation in the same tab", %{page: page, first: first, tab: tab} do
      second = live(first.sid, tab, 3)

      assert {:navigated, %Page{sids: [sid]}} = Page.follow(page, second)
      assert sid == second.sid
    end

    test "keeps following after older sessions expired", %{page: page, first: first, tab: tab} do
      second = live(first.sid, tab, 3)
      {:navigated, page} = Page.follow(page, second)
      Store.put_limits(ttl_ms: 0)
      Store.sweep(System.system_time(:microsecond) + 1_000_000)

      third = live(second.sid, tab, 4)

      assert {:navigated, %Page{sids: [sid]}} = Page.follow(page, third)
      assert sid == third.sid
    end

    test "on another transport, follows a new path but not a duplicate of the page",
         %{page: page, first: first} do
      first_path = "/users"
      page = %{page | path: first_path}
      elsewhere = %{live(first.sid, idle_process(), 3) | path: "/settings"}
      duplicate = %{live(first.sid, idle_process(), 4) | path: first_path}

      assert {:navigated, %Page{path: "/settings"}} = Page.follow(page, elsewhere)
      assert Page.follow(page, duplicate) == :ignore
    end

    test "tracks a rejoin on a new transport", %{page: page, first: first} do
      new_tab = idle_process()

      assert {:rejoined, %Page{transport: ^new_tab, sids: sids}} =
               Page.follow(page, %{first | transport: new_tab})

      assert sids == page.sids
    end

    test "ignores other tabs, sticky LiveViews and unrelated sessions",
         %{page: page, first: first, root: root} do
      duplicated_tab = live(first.sid, idle_process(), 3)
      sticky = live(first.sid, nil, 4)
      stranger = live(root, idle_process(), 5)

      for session <- [duplicated_tab, sticky, stranger, Session.new(:request)] do
        assert Page.follow(page, session) == :ignore
      end
    end
  end
end
