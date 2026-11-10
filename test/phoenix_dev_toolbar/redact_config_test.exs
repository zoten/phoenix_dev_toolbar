defmodule PhoenixDevToolbar.RedactConfigTest do
  # Reads `config :phoenix_dev_toolbar, redact:`: touches the app env.
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.EnvHelpers

  import ExUnit.CaptureLog

  alias PhoenixDevToolbar.Config
  alias PhoenixDevToolbar.Truncate

  test "configured keys are added to the defaults" do
    put_app_env(:redact, ["api_key"])

    assert Truncate.redact(%{"api_key" => "a", "password" => "b", "name" => "c"}) ==
             %{"api_key" => "[REDACTED]", "password" => "[REDACTED]", "name" => "c"}
  end

  test "the merged list has no duplicates" do
    put_app_env(:redact, ["password", "ssn"])

    assert Truncate.redact_keys() == Enum.uniq(Truncate.redact_keys())
    assert "ssn" in Truncate.redact_keys()
  end

  test "the assigns diff honours the merged list" do
    put_app_env(:redact, [:api_key])
    changes = Truncate.changes(%{api_key: "a", password: "b"}, [:api_key, :password])

    refute inspect(changes.values) =~ ~s("a")
    refute inspect(changes.values) =~ ~s("b")
  end

  test "invalid redact entries are dropped with one warning" do
    log =
      capture_log(fn ->
        assert Config.redact(["api_key", ~r/x/, :ssn, 5, {:a, 1}]) == ["api_key", :ssn]
      end)

    assert length(String.split(log, "ignoring `redact`")) == 2
    assert Config.redact(["api_key"]) == ["api_key"]
    assert Config.redact("api_key") == ["api_key"]
  end
end
