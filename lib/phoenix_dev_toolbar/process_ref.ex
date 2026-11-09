defmodule PhoenixDevToolbar.ProcessRef do
  @moduledoc false
  # Turns what someone typed into a local process (ADR 10): a pid (`<0.123.0>`
  # or `0.123.0`) or a registered name (`:code_server`, `code_server`,
  # `MyApp.Repo`, `Elixir.MyApp.Repo`). Names are compared as strings with
  # Process.registered/0: never an atom from the input, not even an existing one
  # (the input must not be able to probe the atom table).

  @max_bytes 128
  @pid_format ~r/^<?(\d+)\.(\d+)\.(\d+)>?$/

  @type error :: :invalid | :not_found | :remote | :dead

  @doc "The local, live process `input` names."
  @spec parse(String.t()) :: {:ok, pid()} | {:error, error()}
  def parse(input) when is_binary(input) and byte_size(input) <= @max_bytes do
    input = String.trim(input)

    case Regex.run(@pid_format, input, capture: :all_but_first) do
      [a, b, c] -> pid(a, b, c)
      nil -> registered(input)
    end
  end

  def parse(_input), do: {:error, :invalid}

  defp pid(a, b, c) do
    ~c"<#{a}.#{b}.#{c}>" |> :erlang.list_to_pid() |> local()
  rescue
    ArgumentError -> {:error, :invalid}
  end

  defp local(pid) when node(pid) != node(), do: {:error, :remote}

  defp local(pid) do
    case Process.alive?(pid) do
      true -> {:ok, pid}
      false -> {:error, :dead}
    end
  end

  defp registered(""), do: {:error, :invalid}

  defp registered(input) do
    with name when is_atom(name) <- Enum.find(Process.registered(), &named?(&1, input)),
         pid when is_pid(pid) <- Process.whereis(name) do
      {:ok, pid}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp named?(name, input), do: Atom.to_string(name) == input or inspect(name) == input
end
