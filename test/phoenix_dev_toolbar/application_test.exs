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

  test "unset outside Mix disables the toolbar and says so" do
    log = capture_log(fn -> assert ToolbarApp.settle_enabled(:error, nil) == :ok end)

    refute PhoenixDevToolbar.enabled?()
    assert log =~ "running outside Mix"
    assert log =~ "only: :dev"
  end

  test "unset under another Mix env disables the toolbar and names the env" do
    for env <- [:prod, :test] do
      delete_app_env(:enabled)

      log = capture_log(fn -> assert ToolbarApp.settle_enabled(:error, env) == :ok end)

      refute PhoenixDevToolbar.enabled?(), "expected disabled for #{inspect(env)}"
      assert log =~ "Mix env is #{inspect(env)}"
      assert log =~ "enabled: false"
      assert log =~ "enabled: true"
      refute log =~ "outside Mix"
    end
  end

  test "settle_redact stores the cleaned list and warns once" do
    put_app_env(:redact, ["api_key", ~r/x/, 5])

    log = capture_log(fn -> assert ToolbarApp.settle_redact(true) == :ok end)

    assert Application.fetch_env!(:phoenix_dev_toolbar, :redact) == ["api_key"]
    assert length(String.split(log, "ignoring `redact`")) == 2

    assert PhoenixDevToolbar.Truncate.redact(%{"api_key" => "a", "password" => "b"}) ==
             %{"api_key" => "[REDACTED]", "password" => "[REDACTED]"}
  end

  test "settle_allowed_origins stores the valid entries and names each dropped one" do
    put_app_env(:allowed_origins, ["https://abc.tunnel.example", "abc.tunnel.example", 5])

    log = capture_log(fn -> assert ToolbarApp.settle_allowed_origins(true) == :ok end)

    assert Application.fetch_env!(:phoenix_dev_toolbar, :allowed_origins) ==
             ["https://abc.tunnel.example"]

    assert log =~ ~s("abc.tunnel.example")
    assert log =~ "5"
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
