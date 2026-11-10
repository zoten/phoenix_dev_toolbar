# Boot check for CI (ADR 01), run as `mix run check_boot.exs` in :dev and :prod.
# The fixture has no Ecto: the toolbar must work without it. In :prod the dependency
# is not part of the build at all (`only: :dev`), so the meaningful assertion is that
# its modules are absent and no telemetry handler of it exists.
toolbar_handlers = fn ->
  Enum.filter(:telemetry.list_handlers([]), &match?(%{id: {PhoenixDevToolbar.Collector, _}}, &1))
end

check = fn description, condition ->
  unless condition, do: raise("boot check failed: #{description}")
  IO.puts("ok: #{description}")
end

check.("Ecto.Adapters.SQL is not loaded", not Code.ensure_loaded?(Ecto.Adapters.SQL))

case Mix.env() do
  :dev ->
    check.("enabled?/0 is true", PhoenixDevToolbar.enabled?())
    check.("the Collector attached telemetry handlers", toolbar_handlers.() != [])

  :prod ->
    check.("the toolbar modules are not in the build", not Code.ensure_loaded?(PhoenixDevToolbar))
    check.("no toolbar telemetry handler", toolbar_handlers.() == [])
end
