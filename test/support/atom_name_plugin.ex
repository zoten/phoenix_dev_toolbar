defmodule PhoenixDevToolbar.TestPlugins.AtomName do
  @moduledoc false
  # A hand written plugin whose name/0 is not a string: Config must skip it.
  # No @behaviour: its name/0 breaks the callback type on purpose.

  def id, do: :atom_name

  def name, do: :atom_name

  def telemetry_events(_config), do: []

  def collect(_event, _payload, _context), do: :skip
end
