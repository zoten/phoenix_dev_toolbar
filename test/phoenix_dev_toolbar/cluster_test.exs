defmodule PhoenixDevToolbar.ClusterTest do
  # The Cluster tab (ADR 12) on the test node, which is not distributed: a
  # second node would need distribution in the test VM.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers

  alias PhoenixDevToolbar.ClusterInfo
  alias PhoenixDevToolbar.Plugins.Cluster

  test "this node is read like any other: processes, memory, OTP, uptime" do
    assert %{alive?: false, node: node, nodes: [row], more: 0} = ClusterInfo.read(1000)
    assert node == node()
    assert %{kind: :self, stats: %{processes: processes, memory: memory, otp: otp}} = row
    assert processes > 0 and memory > 0
    assert otp == to_string(:erlang.system_info(:otp_release))
  end

  test "options: refresh_ms is bounded, unknown ones refused" do
    assert Cluster.init([]) == {:ok, %{refresh_ms: 5000}}
    assert Cluster.init(refresh_ms: 1000) == {:ok, %{refresh_ms: 1000}}
    assert {:error, "refresh_ms must be" <> _rest} = Cluster.init(refresh_ms: 999)
    assert {:error, "unknown options" <> _rest} = Cluster.init(nodes: 3)
  end

  describe "the tab" do
    setup do
      with_configured_plugins([Cluster])
    end

    test "shows this node, and says it is not distributed" do
      panel = open_tab("/demo", "cluster", visible: true)
      _ = render_async(panel)

      assert has_element?(panel, "#pdt-cluster-node", to_string(node()))
      assert has_element?(panel, "#pdt-cluster-local", "not distributed")
      assert has_element?(panel, "#pdt-cluster-nodes tbody tr", "this node")
    end
  end
end
