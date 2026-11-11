defmodule PhoenixDevToolbar.TruncateTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.Config
  alias PhoenixDevToolbar.TestCreds
  alias PhoenixDevToolbar.Truncate

  doctest Truncate

  defp reductions(fun) do
    {:reductions, before} = :erlang.process_info(self(), :reductions)
    result = fun.()
    {:reductions, later} = :erlang.process_info(self(), :reductions)
    {result, later - before}
  end

  describe "frames carrying call arguments" do
    @args [
      "save",
      %{"user" => %{"password" => "hunter2"}},
      %{blob: String.duplicate("x", 100_000)}
    ]
    @frame {DemoWeb.PageLive, :handle_event, @args, [file: ~c"lib/x.ex", line: 1]}

    test "stacktrace, exception_stacktrace and exception_origin print the arity only" do
      host? = fn module -> module == DemoWeb.PageLive end

      lines = [
        Truncate.stacktrace([@frame]),
        Truncate.exception_stacktrace([@frame], host?),
        [Truncate.exception_origin([@frame], host?)]
      ]

      for [line] <- lines do
        assert line =~ "lib/x.ex:1: DemoWeb.PageLive.handle_event/3"
        refute line =~ "["
        refute line =~ "hunter2"
      end
    end

    test "a formatted line is bounded" do
      frame = {Mod, :f, 0, [file: String.to_charlist(String.duplicate("f", 5_000)), line: 1]}

      assert [line] = Truncate.stacktrace([frame])
      assert byte_size(line) <= 2_100
    end
  end

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

  describe "exception_stacktrace/2" do
    defp frame(module, n), do: {module, :fun, n, [file: ~c"lib/f.ex", line: n]}

    test "keeps frames up to the last host frame plus the one after it" do
      frames = [
        frame(MyApp.Page, 1),
        frame(Phoenix.LiveView.Channel, 2),
        frame(MyApp.Helper, 3),
        frame(Phoenix.LiveView.Diff, 4),
        frame(Phoenix.LiveView.Channel, 5),
        frame(:gen_server, 6)
      ]

      trimmed = Truncate.exception_stacktrace(frames, &host?/1)

      # Format adds "(app version) " for loaded dependency modules.
      assert Enum.map(trimmed, &String.replace(&1, ~r/^\(.*?\) /, "")) == [
               "lib/f.ex:1: MyApp.Page.fun/1",
               "lib/f.ex:2: Phoenix.LiveView.Channel.fun/2",
               "lib/f.ex:3: MyApp.Helper.fun/3",
               "lib/f.ex:4: Phoenix.LiveView.Diff.fun/4"
             ]
    end

    test "drops toolbar and telemetry frames and caps at 10" do
      own = [frame(PhoenixDevToolbar.Collector, 0), frame(:telemetry, 0)]
      app = for n <- 1..15, do: frame(MyApp.Page, n)

      frames = Truncate.exception_stacktrace(own ++ app, &host?/1)

      assert length(frames) == 10
      assert hd(frames) == "lib/f.ex:1: MyApp.Page.fun/1"
    end

    test "falls back to the first frames without a host predicate or host frame" do
      frames = for n <- 1..12, do: frame(Phoenix.LiveView.Channel, n)

      assert length(Truncate.exception_stacktrace(frames, nil)) == 10
      assert length(Truncate.exception_stacktrace(frames, &host?/1)) == 10
      assert Truncate.exception_stacktrace(nil, &host?/1) == []
    end

    test "the origin is the first host frame, else the first frame" do
      frames = [frame(Phoenix.LiveView.Channel, 1), frame(MyApp.Page, 2), frame(MyApp.Helper, 3)]

      assert Truncate.exception_origin(frames, &host?/1) =~ "MyApp.Page.fun/2"
      assert Truncate.exception_origin(frames, nil) =~ "Phoenix.LiveView.Channel.fun/1"
      assert Truncate.exception_origin(nil, &host?/1) == nil
    end

    defp host?(module), do: module in [MyApp.Page, MyApp.Helper]
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

    test "cuts list items past the bound" do
      list = for _ <- 1..60, do: %{"password" => "p"}

      redacted = Truncate.redact(list)

      assert length(redacted) == 51
      assert List.last(redacted) == "…"
      assert Enum.all?(Enum.take(redacted, 50), &(&1 == %{"password" => "[REDACTED]"}))
    end

    test "keeps 50 entries of a large map and cuts the rest" do
      map = Map.new(1..10_000, &{&1, %{"password" => "p"}})

      redacted = Truncate.redact(map)

      assert map_size(redacted) == 51
      assert redacted["…"] == "…"
      assert Enum.count(redacted, fn {_k, v} -> v == %{"password" => "[REDACTED]"} end) == 50
    end

    test "a struct past 50 fields becomes a plain map with a cut entry" do
      fields = Map.new(1..60, &{:"f#{&1}", %{password: "p"}})
      struct = Map.put(fields, :__struct__, URI)

      redacted = Truncate.redact(struct)

      refute Map.has_key?(redacted, :__struct__)
      assert redacted["…"] == "…"
      # The fields kept (which ones: map order) are walked: every one redacted.
      {cut, kept} = Map.split(redacted, ["…"])
      assert cut == %{"…" => "…"}
      assert map_size(kept) == 50
      assert Enum.all?(kept, fn {_field, value} -> value == %{password: "[REDACTED]"} end)
    end

    test "walks the proper prefix of an improper list and cuts the tail" do
      assert Truncate.redact([%{password: "hunter2"} | :tail]) == [%{password: "[REDACTED]"}, "…"]
    end

    test "walks the first 50 elements of a tuple and cuts the rest" do
      tuple = List.to_tuple([%{password: "hunter2"} | Enum.to_list(1..50)])

      redacted = Truncate.redact(tuple)

      assert tuple_size(redacted) == 51
      assert elem(redacted, 0) == %{password: "[REDACTED]"}
      assert elem(redacted, 50) == "…"
    end

    test "never returns an unvisited sensitive value, however it is hidden" do
      secret = %{password: "hunter2"}

      deep = Enum.reduce(1..7, secret, fn _, acc -> %{a: acc} end)
      tuple = List.to_tuple([secret | Enum.to_list(1..50)])
      improper = [secret | :tail]
      wide = Map.put(Map.new(1..60, &{&1, 0}), 61, secret)
      far_deep = Enum.reduce(1..5_000, secret, fn _, acc -> [acc] end)

      # What each stays visible as: the walked secret redacted, or the cut.
      # Map order decides whether key 61 of `wide` is among the 50 kept (it
      # differs between OTP releases): its cut entry is what always stays.
      for {value, visible?} <- [
            {deep, &(&1 =~ ~s(password: "[REDACTED]"))},
            {tuple, &(&1 =~ ~s(password: "[REDACTED]"))},
            {improper, &(&1 =~ ~s(password: "[REDACTED]"))},
            {wide, fn _printed_cut_at_50 -> Truncate.redact(wide)["…"] == "…" end},
            {far_deep, &(&1 =~ "[[[[")}
          ] do
        redacted = Truncate.redact(value)

        assert visible?.(Truncate.inspect_value(redacted))
        refute Truncate.inspect_value(redacted) =~ "hunter2"
        refute inspect(redacted, limit: :infinity, printable_limit: :infinity) =~ "hunter2"
      end
    end

    test "a deeply nested sensitive key is still redacted within the budget" do
      deep = Enum.reduce(1..20, %{password: "hunter2"}, fn _, acc -> %{a: acc} end)

      redacted = deep |> Truncate.redact() |> inspect(limit: :infinity)

      refute redacted =~ "hunter2"
      assert redacted =~ ~s(password: "[REDACTED]")
    end

    test "a 1 MB key is matched on a bounded prefix" do
      # Against a 1 KB key in the same run (reduction counts vary with the OTP
      # release), keys built before measuring: about the same cost. An Elixir
      # scan of the whole key costs about 1000 times more; a BIF scan (regex,
      # String.contains?) costs a few reductions and no bound can catch it.
      short_key = String.duplicate("é", 1_000)
      long_key = String.duplicate("é", 500_000)
      {_, short} = reductions(fn -> Truncate.redact(%{short_key => 1}) end)
      {_, cost} = reductions(fn -> Truncate.redact(%{long_key => 1}) end)
      assert cost < short * 3

      long = "Password" <> String.duplicate("x", 1_000_000)
      assert Truncate.redact(%{long => "hunter2"}) == %{long => "[REDACTED]"}
    end

    test "a key whose prefix cut lands mid codepoint does not raise" do
      key = String.duplicate("a", 255) <> "é" <> String.duplicate("b", 1_000)

      assert Truncate.redact(%{key => 1}) == %{key => 1}
    end
  end

  describe "changes/2" do
    test "redacts sensitive values" do
      assert Truncate.changes(%{count: 2, password: "x"}, [:count, :password]) == %{
               keys: [:count, :password],
               values: %{count: "2", password: ~s("[REDACTED]")},
               omitted: 0
             }
    end

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

  describe "structs with only scalar fields" do
    test "integer lists show as lists, not charlists" do
      assert Truncate.preview([7]) =~ "[7]"
      assert Truncate.inspect_value([104, 105]) == "[104, 105]"
    end

    test "preview redacts a sensitive field name" do
      preview = Truncate.preview([%TestCreds{secret_key: "sk_live", user: "ada"}], 2048)

      refute preview =~ "sk_live"
      assert preview =~ "[REDACTED]"
      assert preview =~ "ada"
    end

    test "changes redacts them" do
      %{values: %{cfg: shown}} =
        Truncate.changes(%{cfg: %TestCreds{secret_key: "sk_live", user: "ada"}}, [:cfg])

      refute shown =~ "sk_live"
      assert shown =~ "[REDACTED]"
    end

    test "snapshot redacts them" do
      %{entries: [{:stripe, shown}]} =
        Truncate.snapshot(%{stripe: %TestCreds{secret_key: "sk_live", user: "ada"}})

      refute shown =~ "sk_live"
      assert shown =~ "[REDACTED]"
    end
  end

  describe "snapshot/1" do
    test "previews every assign, sorted, redacted, without change tracking" do
      assigns = %{__changed__: %{}, count: 1, api_token: "abc", user: %{name: "Ada"}}

      assert Truncate.snapshot(assigns) == %{
               entries: [
                 {:api_token, ~s("[REDACTED]")},
                 {:count, "1"},
                 {:user, ~s(%{name: "Ada"})}
               ],
               omitted: 0
             }
    end

    test "keeps at most 100 assigns" do
      assigns = Map.new(1..150, &{:"key_#{&1}", &1})

      assert %{entries: entries, omitted: 50} = Truncate.snapshot(assigns)
      assert length(entries) == 100
    end
  end

  describe "redact/2 node budget" do
    defp wide_value(width) do
      for(
        i <- 1..width,
        into: %{},
        do: {"a#{i}", for(_ <- 1..50, do: for(_ <- 1..50, do: %{"k" => 1}))}
      )
    end

    defp count_nodes(value) when is_map(value),
      do: 1 + (value |> Map.values() |> Enum.map(&count_nodes/1) |> Enum.sum())

    defp count_nodes(value) when is_list(value),
      do: 1 + (value |> Enum.map(&count_nodes/1) |> Enum.sum())

    defp count_nodes(_value), do: 1

    test "a wide and deep value is walked within a fixed node budget" do
      narrow = wide_value(5)
      value = wide_value(200)
      {_, narrow_cost} = reductions(fn -> Truncate.redact(narrow) end)
      {redacted, cost} = reductions(fn -> Truncate.redact(value) end)

      # 40 times wider, about the same cost: the walk stops at the budget.
      assert count_nodes(redacted) <= 2_500
      assert cost < narrow_cost * 2
    end

    test "a sensitive key within the budget is redacted, one beyond it is never shown" do
      filler = Map.new(1..50, &{"f#{&1}", Enum.to_list(1..50)})
      value = %{"a" => %{"user" => %{"password" => "near"}}, "b" => [1, 2]}

      eaten = List.duplicate(filler, 50)
      far = %{"a" => eaten, "m" => %{"note" => "farther"}, "z" => eaten}

      assert %{"a" => %{"user" => %{"password" => "[REDACTED]"}}} = Truncate.redact(value)
      refute inspect(Truncate.redact(far), limit: :infinity) =~ "farther"
      assert inspect(Truncate.redact(far), limit: :infinity) =~ "…"
    end
  end

  describe "preview/3" do
    test "cost and size are bounded however deep the value" do
      deep = Enum.reduce(1..5, :leaf, fn _level, acc -> List.duplicate(acc, 20) end)

      preview = Truncate.preview(deep)

      assert byte_size(preview) <= 360 + byte_size(" [truncated]")
    end

    test "100 strings of 5 KB stay under the byte cap" do
      value = for n <- 1..100, do: String.duplicate("x", 5_000) <> to_string(n)

      assert byte_size(Truncate.preview(value, 2048)) <= 2048 + byte_size(" [truncated]")
    end

    test "a sensitive key past the walk budget is cut, never shown" do
      wide = Map.new(1..19, &{:"k#{&1}", Enum.to_list(1..20)})
      value = Map.put(wide, :zz, %{password: "hunter2"})

      preview = Truncate.preview(value, 100_000)

      refute preview =~ "hunter2"
      # The secret is replaced by the cut mark, siblings stay readable.
      assert preview =~ ~s(zz: "…")
      assert preview =~ "k10: [1, 2, 3"
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

      preview = Truncate.preview(session, 100_000)

      refute preview =~ "s3cret"
      assert preview =~ "secret_key_base: \"[REDACTED]\""
      assert preview =~ "example.com"
    end
  end

  describe "stack args (opt-in call arguments)" do
    defp settings(opts \\ []), do: Config.stack_args(opts)

    defp call(args) do
      {MyApp.Live, :handle_event, args, []}
    end

    defp args_of(frames, settings) do
      Truncate.exception_stack_args(frames, nil, settings)
    end

    test "off by default: no settings, no arguments" do
      assert args_of([call(["save", %{"password" => "hunter2"}])], nil) == nil
      assert Truncate.stack_args([call(["save"])], [], nil) == nil
    end

    test "opted in: redacted by key and bounded per frame" do
      params = %{"password" => "hunter2", "zbio" => String.duplicate("x", 50_000)}

      assert [args] = args_of([call(["save", params, :socket])], settings(bytes: 256))
      assert args =~ "[REDACTED]"
      refute args =~ "hunter2"
      assert byte_size(args) <= 256 + 16
    end

    test "global and per call redact keys come on top of the defaults" do
      s = settings(redact: ["card_number"], rules: [{{MyApp.Live, :handle_event}, ["pin"]}])
      params = %{"card_number" => "4111", "pin" => "1234", "name" => "ann"}

      assert [args] = args_of([call([params])], s)
      refute args =~ "4111"
      refute args =~ "1234"
      assert args =~ "ann"
    end

    test "a :hide rule prints nothing, per module, {m, f} and {m, f, a}" do
      for rule <- [MyApp.Live, {MyApp.Live, :handle_event}, {MyApp.Live, :handle_event, 1}] do
        assert args_of([call(["a"])], settings(rules: [{rule, :hide}])) == nil
      end

      assert [_] =
               args_of([call(["a"])], settings(rules: [{{MyApp.Live, :handle_event, 2}, :hide}]))
    end

    test "the most specific rule wins" do
      rules = [{MyApp.Live, :hide}, {{MyApp.Live, :handle_event}, []}]
      assert [_] = args_of([call(["a"])], settings(rules: rules))

      rules = [{{MyApp.Live, :handle_event}, []}, {{MyApp.Live, :handle_event, 1}, :hide}]
      assert args_of([call(["a"])], settings(rules: rules)) == nil
    end

    test "kept parallel to the stacktrace, nil for frames with an arity" do
      frames = [call(["a"]), {MyApp.Live, :other, 1, []}]
      assert [_, nil] = args_of(frames, settings())
      assert length(Truncate.exception_stacktrace(frames, nil)) == 2
    end

    test "a request stacktrace gets them too, and an arity-only one gets none" do
      assert [_] = Truncate.stack_args([call(["a"])], [], settings())
      assert Truncate.stack_args([{MyApp.Live, :f, 1, []}], [], settings()) == nil
    end

    test "a conn argument never prints cookies, headers or the session" do
      conn =
        :post
        |> Plug.Test.conn("/login", %{"password" => "pw1"})
        |> Plug.Conn.put_req_header("authorization", "Bearer BEARERTOKEN")
        |> Plug.Conn.put_req_header("cookie", "_app_key=COOKIEVALUE")
        |> Plug.Test.init_test_session(%{"user_token" => "SESSIONTOKEN"})
        |> Plug.Conn.fetch_cookies()

      frame = {MyApp.Ctl, :create, [conn, conn.params], []}
      args = Truncate.frame_args(frame, settings(bytes: 8192))

      assert args =~ "Plug.Conn"

      for secret <- ~w(BEARERTOKEN COOKIEVALUE SESSIONTOKEN pw1) do
        refute args =~ secret
      end
    end

    test "header tuples are redacted by their name" do
      headers = [{"authorization", "Bearer BEARERTOKEN"}, {"accept", "text/html"}]
      args = Truncate.frame_args({MyApp.Ctl, :f, [%{req_headers: headers}], []}, settings())

      refute args =~ "BEARERTOKEN"
      assert args =~ "text/html"
    end

    test ":crypto frames are hidden by default, unless the developer writes a rule" do
      frame = {:crypto, :mac, [:hmac, :sha256, "SECRETKEY", "data"], []}

      assert Truncate.frame_args(frame, settings()) == nil
      assert Truncate.frame_args(frame, settings(rules: [{:crypto, []}])) =~ "data"
    end
  end
end
