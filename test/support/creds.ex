defmodule PhoenixDevToolbar.TestCreds do
  @moduledoc false
  # A struct with only scalar fields, one of them named like a secret.
  defstruct [:secret_key, :user]
end
