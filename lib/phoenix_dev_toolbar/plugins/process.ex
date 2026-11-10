defmodule PhoenixDevToolbar.Plugins.Process do
  @moduledoc """
  The Process tab ([ADR 09](https://github.com/zoten/phoenix_dev_toolbar/blob/main/adr/09-process-panel.md)): the page's LiveView process
  (or a nested one): memory, reductions, message queue, links, monitors and the
  tasks it started, read only while the tab is shown. Part of `:defaults`.

      config :phoenix_dev_toolbar,
        plugins: [:defaults, {PhoenixDevToolbar.Plugins.Process, sample_ms: 500}]

  ## Options

  | Option | Meaning | Type | Default |
  | --- | --- | --- | --- |
  | `sample_ms:` | how often the vital signs are read | integer, 250 to 60000 | `1000` |
  | `samples:` | points kept by each sparkline | integer, 2 to 600 | `60` |
  | `relations_ms:` | how often links and monitors are read | integer, 1000 to 300000 | `5000` |

  An unknown option or a value out of range disables the plugin, with a logged
  reason. Process actions (kill, suspend) are off unless `actions:` allows them.
  """

  # Built-in Process tab (ADR 09): the page's LiveView process, read while
  # someone looks. It attaches no telemetry and has no summary: a tab only.
  # Options: PhoenixDevToolbar.ProcessOptions (`sample_ms:`, `samples:`, `relations_ms:`).

  use PhoenixDevToolbar.Plugin, id: :process, name: "Process"

  alias PhoenixDevToolbar.ProcessOptions

  @impl PhoenixDevToolbar.Plugin
  defdelegate init(opts), to: ProcessOptions

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: []

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: :skip

  @impl PhoenixDevToolbar.Plugin
  def panel, do: PhoenixDevToolbar.Panels.Process
end
