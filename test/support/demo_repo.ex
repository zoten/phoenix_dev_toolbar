defmodule DemoWeb.FakeRepo do
  @moduledoc false
  # Only what the Ecto plugin reads from a repo. Real queries are exercised by
  # the dev harness repo (ADR 06).

  @spec config() :: keyword()
  def config, do: [telemetry_prefix: [:demo, :repo]]
end
