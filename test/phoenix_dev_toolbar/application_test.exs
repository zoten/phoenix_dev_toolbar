defmodule PhoenixDevToolbar.ApplicationTest do
  # Touches the :enabled application env and detaches the global telemetry
  # handlers, which other tests rely on.
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.EnvHelpers
  import ExUnit.CaptureLog

  import PhoenixDevToolbar.PageHelpers, only: [attach_plugins: 0]

  alias PhoenixDevToolbar.Application, as: ToolbarApp
  alias PhoenixDevToolbar.Collector

  setup do
    delete_app_env(:enabled)
  end

  test "an explicit value wins in any env" do
    for env <- [nil, :dev, :test, :prod] do
      put_app_env(:enabled, true)
      assert ToolbarApp.settle_enabled({:ok, true}, env) == :ok
      assert PhoenixDevToolbar.enabled?()

      put_app_env(:enabled, false)
      assert ToolbarApp.settle_enabled({:ok, false}, env) == :ok
      refute PhoenixDevToolbar.enabled?()
    end
  end

  test "unset under Mix :dev leaves the toolbar enabled" do
    assert ToolbarApp.settle_enabled(:error, :dev) == :ok
    assert PhoenixDevToolbar.enabled?()
  end

  test "unset anywhere else disables the toolbar and says why" do
    for env <- [nil, :prod, :test] do
      delete_app_env(:enabled)

      log = capture_log(fn -> assert ToolbarApp.settle_enabled(:error, env) == :ok end)

      refute PhoenixDevToolbar.enabled?(), "expected disabled for #{inspect(env)}"
      assert log =~ "only: :dev"
    end
  end

  test "disabled starts no children, enabled starts the stores" do
    assert ToolbarApp.children(false) == []
    assert PhoenixDevToolbar.Store in ToolbarApp.children(true)
  end

  test "disabled attaches no telemetry handlers" do
    on_exit(&attach_plugins/0)
    :ok = Collector.detach()

    assert ToolbarApp.maybe_attach(false) == :ok

    assert for(%{id: {Collector, _event}} <- :telemetry.list_handlers([]), do: :found) == []
  end
end
