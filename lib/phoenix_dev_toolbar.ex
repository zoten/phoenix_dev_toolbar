defmodule PhoenixDevToolbar do
  @moduledoc """
  A dev-only debug toolbar for Phoenix LiveView applications.

  Every entry point of the library is a no-op unless `enabled?/0` returns
  `true`. See [ADR 01](https://github.com/zoten/phoenix_dev_toolbar/blob/main/adr/01-zero-prod-footprint-and-installation.md) for the production footprint rules.
  """

  @doc """
  Returns whether the toolbar is enabled.

  True when `config :phoenix_dev_toolbar, enabled: true`, or when `enabled` is
  unset under Mix env `:dev`. The application settles an unset value at boot:
  in a release or any other Mix env it stores `false`.

  ## Examples

      iex> PhoenixDevToolbar.enabled?()
      true

  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:phoenix_dev_toolbar, :enabled, true) == true
end
