defmodule PhoenixDevToolbar.ApplicationTest do
  # Touches the :enabled application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixDevToolbar.Application, as: ToolbarApp

  setup do
    previous = Application.fetch_env(:phoenix_dev_toolbar, :enabled)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_dev_toolbar, :enabled, value)
        :error -> Application.delete_env(:phoenix_dev_toolbar, :enabled)
      end
    end)

    Application.delete_env(:phoenix_dev_toolbar, :enabled)
  end

  test "an explicit value wins in any env" do
    for env <- [nil, :dev, :test, :prod] do
      Application.put_env(:phoenix_dev_toolbar, :enabled, true)
      assert ToolbarApp.settle_enabled({:ok, true}, env) == :ok
      assert PhoenixDevToolbar.enabled?()

      Application.put_env(:phoenix_dev_toolbar, :enabled, false)
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
      Application.delete_env(:phoenix_dev_toolbar, :enabled)

      log = capture_log(fn -> assert ToolbarApp.settle_enabled(:error, env) == :ok end)

      refute PhoenixDevToolbar.enabled?(), "expected disabled for #{inspect(env)}"
      assert log =~ "only: :dev"
    end
  end

  test "disabled starts no children, enabled starts the stores" do
    assert ToolbarApp.children(false) == []
    assert PhoenixDevToolbar.Store in ToolbarApp.children(true)
  end
end
