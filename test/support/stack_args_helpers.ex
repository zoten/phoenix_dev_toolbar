defmodule PhoenixDevToolbar.StackArgsHelpers do
  @moduledoc false
  # Sets `stack_args:` for one test and restores the config and the attached
  # collector on exit.

  import ExUnit.Callbacks, only: [on_exit: 1]
  import PhoenixDevToolbar.EnvHelpers, only: [put_app_env: 2]

  alias PhoenixDevToolbar.Collector

  @spec put_stack_args(term(), [module()]) :: :ok
  def put_stack_args(config, plugins \\ PhoenixDevToolbar.Application.plugins()) do
    put_app_env(:stack_args, config)

    on_exit(fn -> Collector.attach(PhoenixDevToolbar.Application.plugins()) end)
    Collector.attach(plugins)
  end
end
