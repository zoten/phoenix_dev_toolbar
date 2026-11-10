defmodule DemoWeb.PostgresRepo do
  @moduledoc false
  # A real Postgres repo for the EXPLAIN tests (ADR 08), started by
  # test_helper.exs only when PDT_POSTGRES_URL is set (CI always sets it).
  use Ecto.Repo, otp_app: :phoenix_dev_toolbar, adapter: Ecto.Adapters.Postgres
end
