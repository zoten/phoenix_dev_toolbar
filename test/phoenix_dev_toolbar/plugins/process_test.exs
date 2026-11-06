defmodule PhoenixDevToolbar.Plugins.ProcessTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.Plugins.Process, as: ProcessPlugin

  test "options default, are bounded, and unknown ones are refused" do
    assert {:ok, %{sample_ms: 1000, samples: 60, relations_ms: 5000}} = ProcessPlugin.init([])

    assert {:ok, %{sample_ms: 250, samples: 600, relations_ms: 1000}} =
             ProcessPlugin.init(sample_ms: 250, samples: 600, relations_ms: 1000)

    for [{key, _value}] = bad <- [
          [sample_ms: 100],
          [samples: 1],
          [relations_ms: :fast],
          [samples: 601]
        ] do
      assert {:error, message} = ProcessPlugin.init(bad)
      assert message =~ "#{key} must be an integer"
    end

    assert {:error, "unknown options [:sample]" <> _} = ProcessPlugin.init(sample: 500)
  end

  test "a missing config falls back to the defaults" do
    assert ProcessPlugin.config(nil) == %{sample_ms: 1000, samples: 60, relations_ms: 5000}
  end

  test "it is a tab only: no telemetry, no summary" do
    assert ProcessPlugin.telemetry_events(%{}) == []
    refute function_exported?(ProcessPlugin, :summary_init, 1)
  end
end
