defmodule PhoenixDevToolbar.ApplicationTest do
  # Touches the :enabled application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixDevToolbar.Application, as: ToolbarApp

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_dev_toolbar, :enabled) end)
  end

  test "outside Mix (a release), turns the toolbar off and says why" do
    Application.delete_env(:phoenix_dev_toolbar, :enabled)

    log = capture_log(fn -> assert ToolbarApp.settle_enabled(:error, false) == :ok end)

    refute PhoenixDevToolbar.enabled?()
    assert log =~ "only: :dev"
  end

  test "keeps the default under Mix and any explicit choice" do
    Application.delete_env(:phoenix_dev_toolbar, :enabled)

    assert ToolbarApp.settle_enabled(:error, true) == :ok
    assert PhoenixDevToolbar.enabled?()

    Application.put_env(:phoenix_dev_toolbar, :enabled, true)
    assert ToolbarApp.settle_enabled({:ok, true}, false) == :ok
    assert PhoenixDevToolbar.enabled?()
  end
end
