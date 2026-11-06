defmodule PhoenixDevToolbar.TestPlugins.MessageRaisingError do
  @moduledoc false
  # An exception whose message/1 throws: banners must survive it.
  defexception [:value]

  @impl Exception
  def message(_exception), do: throw(:no_message)
end
