defmodule PhoenixDevToolbar.PluginTest do
  use ExUnit.Case, async: true

  defp compile(opts) do
    Code.compile_string("""
    defmodule PhoenixDevToolbar.PluginTest.Compiled#{System.unique_integer([:positive])} do
      use PhoenixDevToolbar.Plugin, #{opts}
      def telemetry_events(_config), do: []
      def collect(_event, _payload, _context), do: :skip
    end
    """)
  end

  test "use defines id/0, name/0 and a default init/1" do
    [{module, _binary}] = compile(~s(id: :jobs, name: "Jobs"))

    assert {module.id(), module.name(), module.init(a: 1)} == {:jobs, "Jobs", {:ok, [a: 1]}}
  end

  test "the name defaults to the id" do
    [{module, _binary}] = compile("id: :jobs")
    assert module.name() == "jobs"
  end

  defp compile_panel(extra) do
    Code.compile_string("""
    defmodule PhoenixDevToolbar.PluginTest.Panel#{System.unique_integer([:positive])} do
      use PhoenixDevToolbar.Panel
      def handle_reset(_events, socket), do: socket
      def handle_events(_events, socket), do: socket
      def render(assigns), do: ~H""
      #{extra}
    end
    """)
  end

  test "a panel cannot define update/2 or update_many/1" do
    assert [{_module, _binary}] = compile_panel("")

    assert_raise CompileError, ~r/cannot define update\/2/, fn ->
      compile_panel("def update(_assigns, socket), do: {:ok, socket}")
    end

    assert_raise CompileError, ~r/cannot define update_many\/1/, fn ->
      compile_panel("def update_many(list), do: Enum.map(list, &elem(&1, 1))")
    end
  end

  test "rejects bad ids and names at compile time" do
    assert_raise ArgumentError, ~r/expects id: an atom/, fn -> compile(~s(id: "jobs")) end
    assert_raise ArgumentError, ~r/expects id: an atom/, fn -> compile("name: \"x\"") end
    assert_raise ArgumentError, ~r/:client is reserved/, fn -> compile("id: :client") end

    assert_raise ArgumentError, ~r/expects name: a string/, fn ->
      compile("id: :jobs, name: :x")
    end
  end
end
