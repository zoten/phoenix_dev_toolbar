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
end
