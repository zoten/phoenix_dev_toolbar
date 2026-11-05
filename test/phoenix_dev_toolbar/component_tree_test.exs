defmodule PhoenixDevToolbar.ComponentTreeTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.ComponentTree

  # The shape Phoenix.LiveView.Debug.live_components/1 returns.
  defp component(cid, children, id \\ nil),
    do: %{
      cid: cid,
      id: id || "c#{cid}",
      module: DemoWeb.CounterComponent,
      assigns: %{secret: "never kept"},
      children_cids: children
    }

  test "nests components by children_cids, drops assigns" do
    tree = ComponentTree.build([component(2, []), component(1, [2]), component(3, [])])

    assert {[
              %{
                cid: 1,
                id: ~s("c1"),
                module: DemoWeb.CounterComponent,
                children: [%{cid: 2, children: []}]
              },
              %{cid: 3, children: []}
            ], 3} = tree

    refute inspect(tree) =~ "never kept"
  end

  test "is bounded by a node budget and survives cycles and unknown cids" do
    many = for cid <- 1..600, do: component(cid, [])
    assert {nodes, 500} = ComponentTree.build(many, 500)
    assert length(nodes) == 500

    cyclic = [component(1, [2]), component(2, [1, 99])]
    assert {[], 0} = ComponentTree.build(cyclic)

    looped = [component(1, [2]), component(2, [2])]
    assert {[%{cid: 1, children: [%{cid: 2, children: []}]}], 2} = ComponentTree.build(looped)
  end
end
