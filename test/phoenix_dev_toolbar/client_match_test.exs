defmodule PhoenixDevToolbar.ClientMatchTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.ClientMatch

  defp parsed(entry) do
    {:ok, parsed} = ClientMatch.parse(entry)
    parsed
  end

  describe "parse/1" do
    test "bare IPs get a full prefix" do
      assert ClientMatch.parse("10.0.0.7") == {:ok, {{10, 0, 0, 7}, 32}}
      assert ClientMatch.parse("fd00::1") == {:ok, {{0xFD00, 0, 0, 0, 0, 0, 0, 1}, 128}}
    end

    test "CIDR entries keep their prefix" do
      assert ClientMatch.parse("192.168.1.0/24") == {:ok, {{192, 168, 1, 0}, 24}}
      assert ClientMatch.parse("10.0.0.0/0") == {:ok, {{10, 0, 0, 0}, 0}}
      assert ClientMatch.parse("fd00::/8") == {:ok, {{0xFD00, 0, 0, 0, 0, 0, 0, 0}, 8}}
      assert {:ok, {_ip, 128}} = ClientMatch.parse("::1/128")
    end

    test "invalid entries are errors" do
      for bad <- [
            "example.com",
            "300.1.1.1",
            "10.0.0.0/33",
            "::1/129",
            "10.0.0.0/-1",
            "10.0.0.0/x",
            "1.2.3.4/8/9",
            "1.2.3.4/-0",
            "1.2.3.4/+8",
            "::1/-0",
            <<255>>,
            "1.2.3.4/" <> <<255>>,
            ["a" | "b"],
            "",
            :atom,
            42,
            nil,
            {10, 0, 0, 1}
          ] do
        assert ClientMatch.parse(bad) == :error, inspect(bad)
      end
    end
  end

  describe "matches?/2" do
    test "IPv4 ranges" do
      entries = [parsed("192.168.1.0/24"), parsed("10.0.0.7")]
      assert ClientMatch.matches?({192, 168, 1, 200}, entries)
      assert ClientMatch.matches?({10, 0, 0, 7}, entries)
      refute ClientMatch.matches?({192, 168, 2, 1}, entries)
      refute ClientMatch.matches?({10, 0, 0, 8}, entries)
    end

    test "/0 matches every address of its family only" do
      entries = [parsed("0.0.0.0/0")]
      assert ClientMatch.matches?({8, 8, 8, 8}, entries)
      refute ClientMatch.matches?({0, 0, 0, 0, 0, 0, 0, 1}, entries)
    end

    test "IPv6 ranges" do
      entries = [parsed("fd00::/8")]
      assert ClientMatch.matches?({0xFD12, 0, 0, 0, 0, 0, 0, 5}, entries)
      refute ClientMatch.matches?({0xFE80, 0, 0, 0, 0, 0, 0, 5}, entries)
      refute ClientMatch.matches?({0xFD00, 0, 0, 0, 0, 0, 0, 1}, [parsed("10.0.0.0/8")])
    end

    test "IPv4-mapped IPv6 peers compare as IPv4" do
      assert ClientMatch.matches?({0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0105}, [
               parsed("192.168.1.0/24")
             ])
    end

    test "no entries match nothing" do
      refute ClientMatch.matches?({1, 2, 3, 4}, [])
    end
  end

  describe "local?/2" do
    test "matches an own address, mapped or not" do
      assert ClientMatch.local?({192, 168, 1, 5}, [{10, 0, 0, 1}, {192, 168, 1, 5}])
      assert ClientMatch.local?({0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0105}, [{192, 168, 1, 5}])
      refute ClientMatch.local?({192, 168, 1, 6}, [{192, 168, 1, 5}])
      refute ClientMatch.local?({192, 168, 1, 6}, [])
    end
  end

  test "own_addresses/0 returns ip tuples" do
    assert Enum.all?(ClientMatch.own_addresses(), &(tuple_size(&1) in [4, 8]))
  end
end
