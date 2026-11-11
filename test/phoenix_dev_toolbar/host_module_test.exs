defmodule PhoenixDevToolbar.HostModuleTest do
  # Swaps a node global persistent_term.
  use ExUnit.Case, async: false

  alias PhoenixDevToolbar.Collector

  @key {Collector, :host_roots}

  setup do
    saved = :persistent_term.get(@key, :unset)

    on_exit(fn ->
      case saved do
        :unset -> :persistent_term.erase(@key)
        roots -> :persistent_term.put(@key, roots)
      end
    end)

    # `host_module?/1` reads loaded modules only.
    for module <- [Phoenix.LiveView, DemoWeb.PageLive, PhoenixDevToolbar.Truncate],
        do: Code.ensure_loaded!(module)

    :persistent_term.put(@key, {[File.cwd!()], Path.expand("deps")})
    :ok
  end

  test "a dependency module is not host code" do
    refute Collector.host_module?(Phoenix.LiveView)
  end

  test "a module compiled from the project is host code" do
    assert Collector.host_module?(DemoWeb.PageLive)
  end

  test "the toolbar's own modules count as project code when it is the Mix project" do
    assert Collector.host_module?(PhoenixDevToolbar.Truncate)
  end

  test "an unloaded module and a non-atom are not host code" do
    refute Collector.host_module?(Does.Not.Exist)
    refute Collector.host_module?("DemoWeb.PageLive")
    refute Collector.host_module?({:not, :an_atom})
  end

  test "without roots nothing is host code" do
    :persistent_term.erase(@key)
    refute Collector.host_module?(DemoWeb.PageLive)
  end
end
