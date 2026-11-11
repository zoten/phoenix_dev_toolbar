defmodule PhoenixDevToolbar.EnvHelpers do
  @moduledoc false
  # Application env for one test, restored exactly on exit: the previous value,
  # or its absence. Callbacks run last in first out, so nested puts unwind.

  @app :phoenix_dev_toolbar

  @doc "Sets the toolbar's `key` for this test."
  @spec put_app_env(atom(), term()) :: :ok
  def put_app_env(key, value), do: put_env(@app, key, value)

  @doc "Removes the toolbar's `key` for this test."
  @spec delete_app_env(atom()) :: :ok
  def delete_app_env(key) do
    restore_on_exit(@app, key)
    Application.delete_env(@app, key)
  end

  @doc "Sets `app`'s `key` for this test (another app's env, like Phoenix's JSON library)."
  @spec put_env(atom(), atom(), term()) :: :ok
  def put_env(app, key, value) do
    restore_on_exit(app, key)
    Application.put_env(app, key, value)
  end

  defp restore_on_exit(app, key) do
    previous = Application.fetch_env(app, key)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end
