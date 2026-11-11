defmodule PhoenixDevToolbar.StackArgsHelpers do
  @moduledoc false
  # Sets `stack_args:` for one test and restores the config and the attached
  # collector on exit.

  import ExUnit.Callbacks, only: [on_exit: 1]
  import PhoenixDevToolbar.EnvHelpers, only: [put_app_env: 2]

  alias PhoenixDevToolbar.Collector

  @spec put_stack_args(term(), [module()]) :: :ok
  def put_stack_args(config, plugins \\ PhoenixDevToolbar.Application.plugins()) do
    # on_exit runs last in first out: registered first, the re-attach runs
    # after put_app_env restored the env, so it reads the original stack_args.
    on_exit(fn -> Collector.attach(PhoenixDevToolbar.Application.plugins()) end)
    put_app_env(:stack_args, config)
    Collector.attach(plugins)
  end
end
