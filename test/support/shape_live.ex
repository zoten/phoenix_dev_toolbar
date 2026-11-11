defmodule DemoWeb.ShapeLive do
  @moduledoc false
  # A LiveView holding assigns of known weights, and one that can be made busy
  # (`send(pid, {:block, self()})`) until it is sent `:unblock`.
  use Phoenix.LiveView

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(big: Enum.to_list(1..1000), small: [1, 2], title: "secret-title-value")
     |> stream(:posts, [%{id: 1, name: "secret-post-name"}])}
  end

  @impl Phoenix.LiveView
  def handle_info({:block, test}, socket) do
    send(test, :blocked)

    receive do
      :unblock -> :ok
    end

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div id="posts" phx-update="stream">
      <p :for={{id, post} <- @streams.posts} id={id}>{post.name}</p>
    </div>
    """
  end
end
