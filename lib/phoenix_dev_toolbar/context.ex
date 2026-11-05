defmodule PhoenixDevToolbar.Context do
  @moduledoc """
  What a plugin's `c:PhoenixDevToolbar.Plugin.collect/3` knows about the event
  it is handling (ADR 05).

    * `sid`: the page session the event belongs to
    * `source`: `:self` when the emitting process is tracked itself (a request,
      a LiveView), `:caller` for its `$callers` children such as `Task.async`
    * `config`: the plugin's config, as returned by its `init/1`
  """

  alias PhoenixDevToolbar.Context

  @enforce_keys [:sid, :source]
  defstruct [:sid, :source, :config]

  @type source :: :self | :caller
  @type t :: %Context{sid: String.t(), source: source(), config: term()}
end
