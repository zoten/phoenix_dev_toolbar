defmodule PhoenixDevToolbar.ProcessOptions do
  @moduledoc false
  # The options of the tabs that inspect a process (Process, ADR 09; System,
  # ADR 11), validated in their plugin's init/1:
  #
  #   * `sample_ms:` how often the vital signs are read, 1000 by default
  #   * `samples:` how many points the sparklines keep, 60 by default
  #   * `relations_ms:` how often links and monitors are read, 5000 by default

  @defaults [sample_ms: 1000, samples: 60, relations_ms: 5000]
  @bounds [sample_ms: {250, 60_000}, samples: {2, 600}, relations_ms: {1000, 300_000}]

  @type config :: %{
          sample_ms: pos_integer(),
          samples: pos_integer(),
          relations_ms: pos_integer()
        }

  @doc "Validates the options: an unknown one or a value out of bounds is refused."
  @spec init(keyword()) :: {:ok, config()} | {:error, String.t()}
  def init(opts) do
    case Keyword.keys(opts) -- Keyword.keys(@defaults) do
      [] ->
        validate(opts)

      unknown ->
        {:error,
         "unknown options #{inspect(unknown)}, expected #{inspect(Keyword.keys(@defaults))}"}
    end
  end

  defp validate(opts) do
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

  @doc "The config for a nil one (a test shell without init/1), with the defaults."
  @spec config(term()) :: config()
  def config(%{sample_ms: _, samples: _, relations_ms: _} = config), do: config
  def config(_config), do: Map.new(@defaults)
end
