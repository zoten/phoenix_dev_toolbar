defmodule PhoenixDevToolbar.HostileLimits do
  @moduledoc false
  # Stand-in for the Store's limits map: `limits.events_per_second` is a remote
  # call on an atom, so the Store's insert path throws or exits (whichever kind
  # the process dictionary names) without any test branch in production code.

  @key {PhoenixDevToolbar.Store, :limits}

  @doc "Makes `Store.insert/2` throw or exit in this node until `restore/1`."
  @spec install(:throw | :exit) :: :ok
  def install(kind) do
    original = PhoenixDevToolbar.Store.limits()
    Process.put(:pdt_hostile_kind, kind)
    :persistent_term.put(@key, __MODULE__)
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.put(@key, original) end)
  end

  @doc false
  @spec events_per_second() :: no_return()
  def events_per_second do
    case Process.get(:pdt_hostile_kind) do
      :throw -> throw(:hostile)
      :exit -> exit(:hostile)
    end
  end
end
