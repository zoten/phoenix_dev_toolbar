defmodule PhoenixDevToolbar.HostEndpoint do
  @moduledoc false
  # Stands in for an endpoint whose `url: [host: ...]` is set (HostCheck).
  @spec config(atom()) :: term()
  def config(:url), do: [host: "myapp.example"]
  def config(_key), do: nil
end
