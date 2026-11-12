defmodule PhoenixDevToolbar.JsonHelpers do
  @moduledoc false
  # Elixir's built-in `JSON` exists from 1.18. Tests that use it are tagged
  # `:json_module` and excluded on older Elixir, but they still compile there: a
  # direct `JSON.decode!/1` call warns, and CI compiles tests with
  # --warnings-as-errors. The module name is built at runtime, so the compiler
  # (which tracks a literal even through a variable) cannot check the call.

  @doc "Decodes `body` with Elixir's built-in `JSON` (Elixir 1.18+ only)."
  @spec builtin_json_decode!(String.t()) :: term()
  def builtin_json_decode!(body) do
    json = Module.concat(["JSON"])
    json.decode!(body)
  end
end
