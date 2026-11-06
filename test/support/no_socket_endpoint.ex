defmodule PhoenixDevToolbar.NoSocketEndpoint do
  @moduledoc false
  # An endpoint that mounts no LiveView socket, for the panel socket's error path.
  def config(_key), do: nil
  def __sockets__, do: []
end
