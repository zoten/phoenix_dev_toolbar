defmodule PhoenixDevToolbar.Mcp.Json do
  @moduledoc false
  # JSON for the MCP endpoint (ADR 15): one normalizer, then the host's JSON
  # library (`Phoenix.json_library/0`), as the Ecto export does.

  @inspect_opts [limit: 20, printable_limit: 500, pretty: false]
  @max_depth 12

  @type json :: nil | boolean() | number() | String.t() | [json()] | %{String.t() => json()}

  @doc "Normalizes any term to JSON friendly data (string keys, no atoms but nil/booleans)."
  @spec safe(term()) :: json()
  def safe(term), do: safe(term, 0)

  defp safe(_term, depth) when depth > @max_depth, do: "..."
  defp safe(nil, _depth), do: nil
  defp safe(bool, _depth) when is_boolean(bool), do: bool
  defp safe(number, _depth) when is_number(number), do: number
  defp safe(atom, _depth) when is_atom(atom), do: atom_string(atom)
  defp safe(%DateTime{} = dt, _depth), do: DateTime.to_iso8601(dt)
  defp safe(%NaiveDateTime{} = dt, _depth), do: NaiveDateTime.to_iso8601(dt)
  defp safe(%_{} = struct, _depth), do: inspect(struct, @inspect_opts)

  defp safe(map, depth) when is_map(map) do
    Map.new(map, fn {key, value} -> {key_string(key), safe(value, depth + 1)} end)
  end

  defp safe(list, depth) when is_list(list), do: safe_list(list, depth + 1)

  defp safe(binary, _depth) when is_binary(binary) do
    case String.valid?(binary) do
      true -> binary
      false -> inspect(binary, @inspect_opts)
    end
  end

  defp safe(other, _depth), do: inspect(other, @inspect_opts)

  # Improper lists cannot be mapped: inspect them.
  defp safe_list(list, depth) do
    case proper?(list) do
      true -> Enum.map(list, &safe(&1, depth))
      false -> inspect(list, @inspect_opts)
    end
  end

  defp proper?([]), do: true
  defp proper?([_head | tail]), do: proper?(tail)
  defp proper?(_improper), do: false

  defp key_string(key) when is_binary(key) do
    case String.valid?(key) do
      true -> key
      false -> inspect(key, @inspect_opts)
    end
  end

  defp key_string(key) when is_atom(key), do: atom_string(key)
  defp key_string(key), do: inspect(key, @inspect_opts)

  defp atom_string(atom) do
    string = Atom.to_string(atom)

    case String.starts_with?(string, "Elixir.") do
      true -> inspect(atom)
      false -> string
    end
  end

  @doc "Encodes a normalized term to a JSON binary."
  @spec encode!(term()) :: String.t()
  def encode!(term) do
    library = Phoenix.json_library()
    term |> library.encode_to_iodata!() |> IO.iodata_to_binary()
  end

  @doc "Decodes a JSON binary."
  @spec decode(binary()) :: {:ok, term()} | {:error, :parse}
  def decode(binary) when is_binary(binary) do
    case Phoenix.json_library().decode(binary) do
      {:ok, term} -> {:ok, term}
      _error -> {:error, :parse}
    end
  rescue
    _error -> {:error, :parse}
  end
end
