defmodule PhoenixDevToolbar.Event do
  @moduledoc """
  One recorded fact: a query, a callback, a request (ADR 05).

  Plugins build events with `new/4` in `c:PhoenixDevToolbar.Plugin.collect/3`.
  `plugin` is the plugin's id, `kind` an atom of the plugin's choosing, `data`
  a map that must already be bounded (see `PhoenixDevToolbar.Truncate`): it is
  stored as is. `sid` and `seq` are set by the toolbar on insert; `plugin` and
  `span` (the callback span, see `PhoenixDevToolbar.Context`) are stamped by the
  collector.
  """

  alias PhoenixDevToolbar.Event

  @enforce_keys [:plugin, :kind, :at]
  defstruct sid: nil,
            seq: nil,
            plugin: nil,
            span: nil,
            kind: nil,
            at: nil,
            duration: nil,
            data: %{}

  @type t :: %Event{
          sid: String.t() | nil,
          seq: pos_integer() | nil,
          plugin: atom(),
          span: non_neg_integer() | nil,
          kind: atom(),
          at: integer(),
          duration: non_neg_integer() | nil,
          data: map()
        }

  @doc """
  Builds an event stamped with the current system time in microseconds.

  `:duration` is given in native time units (as `:telemetry` reports it) and
  stored in microseconds.
  """
  @spec new(atom(), atom(), map(), keyword()) :: t()
  def new(plugin, kind, data, opts \\ [])
      when is_atom(plugin) and is_atom(kind) and is_map(data) do
    %Event{
      plugin: plugin,
      kind: kind,
      at: Keyword.get_lazy(opts, :at, fn -> System.system_time(:microsecond) end),
      duration: native_to_us(opts[:duration]),
      data: data
    }
  end

  @doc """
  Converts a native time duration to microseconds, passing `nil` through.

      iex> PhoenixDevToolbar.Event.native_to_us(nil)
      nil

      iex> PhoenixDevToolbar.Event.native_to_us(System.convert_time_unit(3, :millisecond, :native))
      3000

  """
  @spec native_to_us(integer() | nil) :: non_neg_integer() | nil
  def native_to_us(nil), do: nil

  def native_to_us(native) when is_integer(native),
    do: System.convert_time_unit(native, :native, :microsecond)
end
