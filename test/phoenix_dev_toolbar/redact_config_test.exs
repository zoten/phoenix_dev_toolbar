defmodule PhoenixDevToolbar.RedactConfigTest do
  # Reads `config :phoenix_dev_toolbar, redact:`: touches the app env.
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.EnvHelpers

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
end
