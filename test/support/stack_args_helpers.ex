defmodule PhoenixDevToolbar.StackArgsHelpers do
  @moduledoc false
  # Sets `stack_args:` for one test and restores the config and the attached
  # collector on exit.

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias PhoenixDevToolbar.Collector

  @spec put_stack_args(term(), [module()]) :: :ok
  def put_stack_args(config, plugins \\ PhoenixDevToolbar.Application.plugins()) do
    previous = Application.fetch_env(:phoenix_dev_toolbar, :stack_args)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_dev_toolbar, :stack_args, value)
        :error -> Application.delete_env(:phoenix_dev_toolbar, :stack_args)
      end

      Collector.attach(PhoenixDevToolbar.Application.plugins())
    end)

    Application.put_env(:phoenix_dev_toolbar, :stack_args, config)
    Collector.attach(plugins)
  end
end
