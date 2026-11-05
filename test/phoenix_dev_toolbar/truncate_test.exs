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

    test "keeps every entry of a large map and walks a bounded number of them" do
      map = Map.new(1..10_000, &{&1, %{"password" => "p"}})

      redacted = Truncate.redact(map)

      assert map_size(redacted) == 10_000
      assert Enum.count(redacted, fn {_k, v} -> v == %{"password" => "[REDACTED]"} end) == 50
    end

    test "returns improper lists unchanged" do
      assert Truncate.redact([1 | 2]) == [1 | 2]
    end

    test "stops descending past the depth bound" do
      deep = Enum.reduce(1..10, %{"password" => "p"}, fn _, acc -> %{"next" => acc} end)

      assert get_in(Truncate.redact(deep), List.duplicate("next", 10)) == %{"password" => "p"}
    end
  end

  describe "changes/2" do
    test "inspects the changed values, sorted by key" do
      assigns = %{__changed__: %{}, count: 2, name: "Ada", other: :untouched}

      assert Truncate.changes(assigns, [:name, :count]) == %{
               keys: [:count, :name],
               values: %{count: "2", name: ~s("Ada")},
               omitted: 0
             }
    end

    test "redacts sensitive keys and nested values" do
      assigns = %{api_token: "abc", user: %{password: "hunter2", name: "Ada"}}

      %{values: values} = Truncate.changes(assigns, [:api_token, :user])

      assert values.api_token == ~s("[REDACTED]")
      assert values.user =~ "[REDACTED]"
      refute values.user =~ "hunter2"
    end

    test ":all lists every assign except change tracking" do
      assigns = %{__changed__: nil, a: 1, b: 2}

      assert %{keys: [:a, :b]} = Truncate.changes(assigns, :all)
    end

    test "flash is listed but its value is not stored" do
      assigns = %{flash: %{"info" => "Saved"}}

      assert %{keys: [:flash], values: values} = Truncate.changes(assigns, [:flash])
      refute Map.has_key?(values, :flash)
    end

    test "keys missing from the assigns are listed without a value" do
      assert %{keys: [:gone], values: values} = Truncate.changes(%{}, [:gone])
      assert values == %{}
    end

    test "is bounded: 20 keys, 10 values, about 4 KB however large the assigns" do
      huge = Map.new(1..200, &{:"key_#{&1}", Enum.to_list(1..10_000)})
      nested = Enum.reduce(1..50, :leaf, &%{level: &1, inner: &2, list: Enum.to_list(1..100)})
      assigns = Map.put(huge, :key_1, nested)

      changes = Truncate.changes(assigns, Map.keys(assigns))

      assert length(changes.keys) == 20
      assert changes.omitted == 180
      assert map_size(changes.values) == 10
      assert changes |> :erlang.term_to_binary() |> byte_size() < 4_500
    end
  end

  describe "preview/3" do
    test "cost and size are bounded however deep the value" do
      deep = Enum.reduce(1..5, :leaf, fn _level, acc -> List.duplicate(acc, 20) end)

      preview = Truncate.preview(deep)

      assert byte_size(preview) <= 360 + byte_size(" [truncated]")
    end

    test "a sensitive key past the walk budget is cut, never shown" do
      wide = Map.new(1..19, &{:"k#{&1}", Enum.to_list(1..20)})
      value = Map.put(wide, :zz, %{password: "hunter2"})

      refute Truncate.preview(value, 100_000) =~ "hunter2"
    end

    test "redacts keyword lists inside lists and tuples" do
      assert Truncate.preview({:ok, [api_token: "abc", page: 1]}) ==
               ~s({:ok, [api_token: "[REDACTED]", page: 1]})
    end

    test "scalar structs keep their own inspect" do
      assert Truncate.preview(~U[2026-11-05 10:00:00Z]) == "~U[2026-11-05 10:00:00Z]"
      assert Truncate.preview(%{at: ~D[2026-11-05]}) == "%{at: ~D[2026-11-05]}"
    end

    test "nested structs are walked and redacted" do
      uri = %URI{host: "example.com", query: "a=1", userinfo: "ada:hunter2"}
      session = %{__struct__: Plug.Conn, secret_key_base: "s3cret", assigns: %{uri: uri}}

      refute Truncate.preview(session, 100_000) =~ "s3cret"
    end
  end
end
