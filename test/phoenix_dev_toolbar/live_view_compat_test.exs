defmodule PhoenixDevToolbar.LiveViewCompatTest do
  # Not async: the "changed shape" warning is logged once per node.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Phoenix.LiveView.Socket
  alias PhoenixDevToolbar.LiveViewCompat

  # Sockets are built through LiveView's public API, so these tests break when
  # the installed LiveView changes the internals LiveViewCompat reads.
  defp socket, do: %Socket{}

  describe "changed_keys/1" do
    test "lists the keys assigned since the last render" do
      socket = socket() |> Phoenix.Component.assign(count: 1, name: "Ada")

      assert socket |> LiveViewCompat.changed_keys() |> Enum.sort() == [:count, :name]
    end

    test "is empty when nothing changed" do
      assert LiveViewCompat.changed_keys(socket()) == []
    end

    test "is :all when change tracking is off" do
      socket = %Socket{assigns: %{__changed__: nil, count: 1}}

      assert LiveViewCompat.changed_keys(socket) == :all
    end
  end

  describe "live_view_label/1" do
    test "reads the view a LiveView process labels itself with" do
      parent = self()

      pid =
        spawn(fn ->
          Process.put(:"$process_label", {Phoenix.LiveView, DemoWeb.PageLive, "lv:phx-1"})
          send(parent, :labelled)
          receive(do: (:stop -> :ok))
        end)

      on_exit(fn -> send(pid, :stop) end)
      assert_receive :labelled

      assert LiveViewCompat.live_view_label(pid) == {:ok, DemoWeb.PageLive}
    end

    test "is :error for other or dead processes" do
      assert LiveViewCompat.live_view_label(self()) == :error

      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}
      assert LiveViewCompat.live_view_label(dead) == :error
    end
  end

  describe "push_event_names/1" do
    setup do
      LiveViewCompat.reset_warnings()
      on_exit(&LiveViewCompat.reset_warnings/0)
    end

    test "returns pushed event names in push order, never payloads" do
      socket =
        socket()
        |> Phoenix.LiveView.push_event("highlight", %{id: 1})
        |> Phoenix.LiveView.push_event("scroll-to", %{secret: "x"}, dispatch: :before)

      assert LiveViewCompat.push_event_names(socket) == {:ok, ["highlight", "scroll-to"]}
    end

    test "returns an empty list when nothing was pushed" do
      assert LiveViewCompat.push_event_names(socket()) == {:ok, []}
    end

    test "keeps the last 10 names, in push order" do
      socket =
        Enum.reduce(1..15, socket(), fn n, acc ->
          Phoenix.LiveView.push_event(acc, "event-#{n}", %{})
        end)

      assert LiveViewCompat.push_event_names(socket) ==
               {:ok, for(n <- 6..15, do: "event-#{n}")}
    end

    test "truncates long names" do
      socket = Phoenix.LiveView.push_event(socket(), String.duplicate("e", 500), %{})

      assert {:ok, [name]} = LiveViewCompat.push_event_names(socket)
      assert byte_size(name) <= 140
    end

    test "a changed internal shape degrades to :unavailable and warns once" do
      socket = %Socket{private: %{live_temp: %{push_events: :unexpected}}}

      log =
        capture_log(fn ->
          assert LiveViewCompat.push_event_names(socket) == :unavailable
          assert LiveViewCompat.push_event_names(%Socket{private: %{}}) == :unavailable
        end)

      assert [_one] = Regex.scan(~r/push_event names unavailable/, log)
      assert log =~ "phoenix_live_view"
    end
  end

  describe "component_to_html_error?/1" do
    test "recognises LiveView refusing to turn a live component into HTML" do
      component = %Phoenix.LiveView.Component{id: "c", component: DemoWeb.CounterComponent}
      error = catch_error(Phoenix.HTML.Safe.to_iodata(component))

      assert LiveViewCompat.component_to_html_error?(error)
      refute LiveViewCompat.component_to_html_error?(%ArgumentError{message: "other"})
      refute LiveViewCompat.component_to_html_error?(%RuntimeError{message: "cannot convert"})
    end
  end
end
