defmodule PhoenixDevToolbar.TrackerTest do
  # Drives the real mount telemetry event through the attached Collector.
  #
  # Mirrors LiveView 1.2 behaviour: the socket id is created by the dead render
  # and kept across live navigation (the client rejoins with the same id) and
  # across reconnects (new transport) and crash rejoins (same transport).
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.ProcessHelpers

  alias Phoenix.LiveView.Socket
  alias PhoenixDevToolbar.Attribution
  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @users "http://localhost:4000/users?page=2"
  @settings "http://localhost:4000/settings"

  setup do
    Store.reset()
    on_exit(&Store.reset/0)

    %Session{sid: request_sid} = Store.new_session(Session.new(:request))
    transport = idle_process()
    dead_render(request_sid, "phx-1")

    %{request_sid: request_sid, transport: transport}
  end

  defp socket(id, attrs) do
    struct!(%Socket{id: id, view: DemoWeb.PageLive}, attrs)
  end

  defp mount(%Socket{} = socket, uri) do
    :telemetry.execute([:phoenix, :live_view, :mount, :start], %{system_time: 0}, %{
      socket: socket,
      params: %{},
      session: %{},
      uri: uri
    })
  end

  # Mounts in a fresh process, as LiveView does, and returns {pid, tracked sid}.
  defp connected_mount(%Socket{} = socket, uri \\ @users) do
    in_process(fn ->
      mount(socket, uri)
      Attribution.tracked_sid()
    end)
  end

  defp dead_render(request_sid, socket_id) do
    in_process(fn ->
      Attribution.track(request_sid)
      mount(socket(socket_id, []), @users)
    end)
  end

  test "links the connected mount to the dead render as a child LiveView session",
       %{request_sid: request_sid, transport: transport} do
    Notify.subscribe(request_sid)

    {pid, sid} = connected_mount(socket("phx-1", transport_pid: transport))

    assert {:ok, %Session{kind: :live_view, parent: ^request_sid, owner: ^pid, path: "/users"}} =
             Store.session(sid)

    assert Store.latest_for_transport(transport) == sid
    assert_receive {:pdt_session, ^sid}
  end

  test "live navigation keeps the socket id but starts a child session",
       %{transport: transport} do
    {_pid, first} = connected_mount(socket("phx-1", transport_pid: transport))
    Notify.subscribe(first)

    {_pid, second} = connected_mount(socket("phx-1", transport_pid: transport), @settings)

    assert second != first
    assert {:ok, %Session{parent: ^first, path: "/settings"}} = Store.session(second)
    assert Store.latest_for_transport(transport) == second
    assert_receive {:pdt_session, ^second}
  end

  test "a reconnect on a new transport claims the session of the dead owner",
       %{request_sid: request_sid, transport: transport} do
    {old_owner, sid} = connected_mount(socket("phx-1", transport_pid: transport))
    stop(old_owner)
    Notify.subscribe(request_sid)

    new_transport = idle_process()
    {new_owner, again} = connected_mount(socket("phx-1", transport_pid: new_transport))

    assert again == sid
    assert {:ok, %Session{owner: ^new_owner, transport: ^new_transport}} = Store.session(sid)
    assert Store.latest_for_transport(new_transport) == sid
    assert_receive {:pdt_session, ^sid}
  end

  test "a duplicated tab does not steal the session of a live owner",
       %{transport: transport} do
    {owner, sid} = connected_mount(socket("phx-1", transport_pid: transport))

    {_pid, copy} = connected_mount(socket("phx-1", transport_pid: idle_process()))

    assert copy != sid
    assert {:ok, %Session{owner: ^owner}} = Store.session(sid)
    assert {:ok, %Session{parent: ^sid}} = Store.session(copy)
  end

  test "nested LiveViews share their parent's session, even without a sticky param",
       %{transport: transport} do
    {parent_pid, sid} = connected_mount(socket("phx-1", transport_pid: transport))

    {_pid, nested} =
      connected_mount(
        socket("phx-nested", transport_pid: transport, parent_pid: parent_pid, sticky?: nil)
      )

    assert nested == sid
    assert Store.latest_for_transport(transport) == sid
  end

  test "sticky LiveViews get a session that never becomes the tab's latest",
       %{transport: transport} do
    {_pid, main} = connected_mount(socket("phx-1", transport_pid: transport))

    {_pid, sticky} =
      connected_mount(socket("phx-sticky", transport_pid: transport, sticky?: true))

    assert {:ok, %Session{transport: nil}} = Store.session(sticky)
    assert Store.latest_for_transport(transport) == main
  end

  test "never tracks the toolbar's own LiveViews", %{transport: transport} do
    {_pid, sid} =
      connected_mount(
        socket("phx-panel", transport_pid: transport, view: PhoenixDevToolbar.TestOwnLive)
      )

    assert sid == nil
    assert Store.latest_for_transport(transport) == nil
  end
end
