defmodule PhoenixDevToolbar.Plugins.System do
  @moduledoc """
  The System tab ([ADR 11](https://github.com/zoten/phoenix_dev_toolbar/blob/main/adr/11-system-tab.md)): any local process, by pid or
  registered name or through a link from another tab, with the same vital signs
  as the Process tab plus ancestors, stacktrace and state. Reads nothing until
  someone inspects a process. Part of `:defaults`.

      config :phoenix_dev_toolbar,
        plugins: [:defaults, {PhoenixDevToolbar.Plugins.System, samples: 120}]

  ## Options

  | Option | Meaning | Type | Default |
  | --- | --- | --- | --- |
  | `sample_ms:` | how often the vital signs are read | integer, 250 to 60000 | `1000` |
  | `samples:` | points kept by each sparkline | integer, 2 to 600 | `60` |
  | `relations_ms:` | how often links and monitors are read | integer, 1000 to 300000 | `5000` |

  An unknown option or a value out of range disables the plugin, with a logged
  reason. Process actions (kill, suspend) are off unless `actions:` allows them.
  """

  # Built-in System tab (ADR 11): any local process, by pid, registered name or
  # a link from another tab. It attaches no telemetry and has no summary: a tab
  # only, reading nothing until someone inspects a process.
  # Options: PhoenixDevToolbar.ProcessOptions (`sample_ms:`, `samples:`, `relations_ms:`).

  use PhoenixDevToolbar.Plugin, id: :system, name: "System"

  alias PhoenixDevToolbar.ProcessOptions

  @impl PhoenixDevToolbar.Plugin
  defdelegate init(opts), to: ProcessOptions

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: []

  @impl PhoenixDevToolbar.Plugin
  def collect(_event, _payload, _context), do: :skip

  @impl PhoenixDevToolbar.Plugin
  def panel, do: PhoenixDevToolbar.Panels.System
end
