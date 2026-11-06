defmodule PhoenixDevToolbar.Plugins.Process do
  @moduledoc false
  # Built-in Process tab (ADR 09): the page's LiveView process, read while
  # someone looks. It attaches no telemetry and has no summary: a tab only.
  #
  # Options (validated in init/1):
  #   * `sample_ms:` how often the vital signs are read, 1000 by default
  #   * `samples:` how many points the sparklines keep, 60 by default
  #   * `relations_ms:` how often links and monitors are read, 5000 by default

  use PhoenixDevToolbar.Plugin, id: :process, name: "Process"

  @defaults [sample_ms: 1000, samples: 60, relations_ms: 5000]
  @bounds [sample_ms: {250, 60_000}, samples: {2, 600}, relations_ms: {1000, 300_000}]

  @impl true
  def init(opts) do
    Enum.reduce_while(@defaults, {:ok, %{}}, fn {key, default}, {:ok, config} ->
      {min, max} = @bounds[key]

      case Keyword.get(opts, key, default) do
        value when is_integer(value) and value >= min and value <= max ->
          {:cont, {:ok, Map.put(config, key, value)}}

        other ->
          {:halt,
           {:error,
            "#{key} must be an integer from #{min} to #{max}, got: #{inspect(other, limit: 5)}"}}
      end
    end)
  end

  @doc false
  # The config for a nil one (a test shell without init/1), with the defaults.
  @spec config(term()) :: %{
          sample_ms: pos_integer(),
          samples: pos_integer(),
          relations_ms: pos_integer()
        }
  def config(%{sample_ms: _, samples: _, relations_ms: _} = config), do: config
  def config(_config), do: Map.new(@defaults)

  @impl true
  def telemetry_events(_config), do: []

  @impl true
  def collect(_event, _payload, _context), do: :skip

  @impl true
  def panel, do: PhoenixDevToolbar.Panels.Process
end
