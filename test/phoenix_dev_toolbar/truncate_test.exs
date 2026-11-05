defmodule PhoenixDevToolbar.TruncateTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.Truncate

  doctest Truncate

  describe "sql/1" do
    test "caps long SQL and marks it truncated" do
      sql = "SELECT " <> String.duplicate("a", 10_000)

      assert Truncate.sql(sql) == binary_part(sql, 0, 8192) <> " [truncated]"
    end

    test "never splits a UTF-8 codepoint" do
      # 8191 ASCII bytes then a 2-byte codepoint straddling the limit
      sql = String.duplicate("a", 8191) <> "é" <> String.duplicate("b", 100)

      assert Truncate.sql(sql) == String.duplicate("a", 8191) <> " [truncated]"
    end
  end

  describe "stacktrace/1" do
    test "drops toolbar and telemetry frames and keeps at most 10" do
      own = [
        {PhoenixDevToolbar.Collector, :handle, 4, [file: ~c"lib/collector.ex", line: 1]},
        {:telemetry, :execute, 3, [file: ~c"src/telemetry.erl", line: 1]}
      ]

      app = for n <- 1..15, do: {MyApp.Mod, :fun, n, [file: ~c"lib/mod.ex", line: n]}

      frames = Truncate.stacktrace(own ++ app)

      assert length(frames) == 10
      assert hd(frames) == "lib/mod.ex:1: MyApp.Mod.fun/1"
    end

    test "keeps modules that only share the toolbar name prefix" do
      frame = {PhoenixDevToolbarDemo.Page, :run, 0, [file: ~c"lib/page.ex", line: 2]}

      assert Truncate.stacktrace([frame]) == ["lib/page.ex:2: PhoenixDevToolbarDemo.Page.run/0"]
    end
  end

  describe "redact/2" do
    test "matches key names case insensitively, atom or string" do
      assert Truncate.redact(%{"X-Auth-Token" => "y", Password: "x", name: "z"}) ==
               %{"X-Auth-Token" => "[REDACTED]", Password: "[REDACTED]", name: "z"}
    end

    test "walks structs and keeps their type" do
      uri = %URI{userinfo: "secret", host: "example.com"}

      assert %URI{host: "example.com", userinfo: "secret"} = Truncate.redact(uri)
      assert %URI{userinfo: "[REDACTED]"} = Truncate.redact(uri, ["userinfo"])
    end

    test "accepts custom keys" do
      assert Truncate.redact(%{"ssn" => "1", "password" => "2"}, [:ssn]) ==
               %{"ssn" => "[REDACTED]", "password" => "2"}
    end

    test "leaves list items past the bound untouched" do
      list = for _ <- 1..60, do: %{"password" => "p"}

      {head, tail} = list |> Truncate.redact() |> Enum.split(50)

      assert Enum.all?(head, &(&1 == %{"password" => "[REDACTED]"}))
      assert Enum.all?(tail, &(&1 == %{"password" => "p"}))
    end

    test "returns improper lists unchanged" do
      assert Truncate.redact([1 | 2]) == [1 | 2]
    end

    test "stops descending past the depth bound" do
      deep = Enum.reduce(1..10, %{"password" => "p"}, fn _, acc -> %{"next" => acc} end)

      assert get_in(Truncate.redact(deep), List.duplicate("next", 10)) == %{"password" => "p"}
    end
  end
end
