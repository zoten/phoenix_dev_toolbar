defmodule PhoenixDevToolbar.Context do
  @moduledoc false
  # What a plugin collector knows about the event it is handling (ADR 05).
  # `source` is `:self` for tracked processes and `:caller` for `$callers`
  # children such as `Task.async`.

  alias PhoenixDevToolbar.Context
  alias PhoenixDevToolbar.Session

  @enforce_keys [:sid, :source]
  defstruct [:sid, :source]

  @type source :: :self | :caller
  @type t :: %Context{sid: Session.sid(), source: source()}
end
