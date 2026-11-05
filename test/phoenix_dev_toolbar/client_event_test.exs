defmodule PhoenixDevToolbar.ClientEventTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.ClientEvent
  alias PhoenixDevToolbar.Event

  describe "build/2" do
    test "keeps only known fields holding scalars, strings capped" do
      payload = %{
        "type" => "phx:navigate",
        "at" => 1_700_000_000_000,
        "href" => String.duplicate("a", 1000),
        "patch" => true,
        "kind" => %{"nested" => "object"},
        "secret" => "not a field"
      }

      assert {:ok, %Event{plugin: :client, at: 1_700_000_000_000_000, data: data}} =
               ClientEvent.build(payload, 3)

      assert %{type: "phx:navigate", n: 3, fields: [{"href", href}, {"patch", true}]} = data
      assert byte_size(href) < 300
    end

    test "ignores unknown types and non maps, replaces out of range timestamps" do
      assert ClientEvent.build(%{"type" => "phx:custom"}, 1) == :ignore
      assert ClientEvent.build("nope", 1) == :ignore
      assert ClientEvent.build(nil, 1) == :ignore

      before = System.system_time(:microsecond)
      {:ok, event} = ClientEvent.build(%{"type" => "phx:navigate", "at" => -5}, 1)
      assert event.at >= before
    end
  end

  test "dropped/2 only grows and ignores invalid counts" do
    assert ClientEvent.dropped(7, 3) == 7
    assert ClientEvent.dropped(1, 3) == 3
    assert ClientEvent.dropped(-1, 3) == 3
    assert ClientEvent.dropped("9", 3) == 3
  end

  test "remembers the last events and returns those of the last 2 s, oldest first" do
    events = for n <- 1..12, do: Event.new(:client, :client, %{n: n}, at: 0)

    recent =
      events
      |> Enum.with_index()
      |> Enum.reduce([], fn {event, i}, acc -> ClientEvent.remember(acc, event, i * 500) end)

    # 12 remembered at 0..5500 ms: the last 10 kept, those since 3500 ms (inclusive) returned.
    assert length(recent) == 10
    assert Enum.map(ClientEvent.recent(recent, 5500), & &1.data.n) == [8, 9, 10, 11, 12]
  end
end
