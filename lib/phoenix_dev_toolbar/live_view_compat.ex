defmodule PhoenixDevToolbar.LiveViewCompat do
  @moduledoc false
  # The only module allowed to look inside `Phoenix.LiveView.Socket` (ADR 02).
  # Verified against LiveView 1.1 and 1.2; covered by the CI version matrix.

  alias Phoenix.LiveView.Socket

  @type info :: %{
          id: String.t(),
          view: module(),
          connected?: boolean(),
          transport: pid() | nil,
          parent: pid() | nil,
          sticky?: boolean()
        }

  @spec info(Socket.t()) :: info()
  def info(%Socket{} = socket) do
    %{
      id: socket.id,
      view: socket.view,
      connected?: Phoenix.LiveView.connected?(socket),
      transport: socket.transport_pid,
      parent: socket.parent_pid,
      # The channel copies the client's "sticky" join param as is: nil for
      # clients that do not send it (Phoenix.LiveViewTest), so normalise.
      sticky?: socket.sticky? == true
    }
  end
end
