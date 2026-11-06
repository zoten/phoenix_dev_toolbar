defmodule DemoWeb.SQLiteRepo do
  @moduledoc false
  # A real SQL repo for the EXPLAIN tests (ADR 08): SQLite in tmp/, created by
  # test_helper.exs. Other Ecto tests use DemoWeb.FakeRepo (no database).
  use Ecto.Repo, otp_app: :phoenix_dev_toolbar, adapter: Ecto.Adapters.SQLite3
end
