defmodule PhoenixDevToolbar.Context do
  @moduledoc """
  What a plugin's `c:PhoenixDevToolbar.Plugin.collect/3` knows about the event
  it is handling (ADR 05).

    * `sid`: the page session the event belongs to
    * `source`: `:self` when the emitting process is tracked itself (a request,
      a LiveView), `:caller` for its `$callers` children such as `Task.async`
    * `config`: the plugin's config, as returned by its `init/1`
    * `span`: the callback span the event happened in: a counter bumped at
      every LiveView callback start and stop in the tracked process (so one
      `handle_event/3`, one `render/1`, or the gap between two callbacks where
      `handle_info/2` runs). A `$callers` child gets its caller's span. Events
      are stamped with it (`Event.span`).
  """

  alias PhoenixDevToolbar.Context

  @enforce_keys [:sid, :source]
  defstruct [:sid, :source, :config, span: 0]

  @type source :: :self | :caller
  @type t :: %Context{
          sid: String.t(),
          source: source(),
          config: term(),
          span: non_neg_integer()
        }
end
