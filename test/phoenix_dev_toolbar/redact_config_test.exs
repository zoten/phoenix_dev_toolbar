defmodule PhoenixDevToolbar.RedactConfigTest do
  # Reads `config :phoenix_dev_toolbar, redact:`: touches the app env.
  use ExUnit.Case, async: false

  alias PhoenixDevToolbar.Truncate

  setup do
    previous = Application.fetch_env(:phoenix_dev_toolbar, :redact)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_dev_toolbar, :redact, value)
        :error -> Application.delete_env(:phoenix_dev_toolbar, :redact)
      end
    end)
  end

  test "configured keys are added to the defaults" do
    Application.put_env(:phoenix_dev_toolbar, :redact, ["api_key"])

    assert Truncate.redact(%{"api_key" => "a", "password" => "b", "name" => "c"}) ==
             %{"api_key" => "[REDACTED]", "password" => "[REDACTED]", "name" => "c"}
  end

  test "the merged list has no duplicates" do
    Application.put_env(:phoenix_dev_toolbar, :redact, ["password", "ssn"])

    assert Truncate.redact_keys() == Enum.uniq(Truncate.redact_keys())
    assert "ssn" in Truncate.redact_keys()
  end

  test "the assigns diff honours the merged list" do
    Application.put_env(:phoenix_dev_toolbar, :redact, [:api_key])
    changes = Truncate.changes(%{api_key: "a", password: "b"}, [:api_key, :password])

    refute inspect(changes.values) =~ ~s("a")
    refute inspect(changes.values) =~ ~s("b")
  end
end
