defmodule DemoWeb.ComponentsLive do
  @moduledoc false
  # A host LiveView with a LiveComponent, a push_event and a sensitive assign,
  # driven end to end by the LiveView plugin and panel tests.
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, clicks: 0, api_token: "s3cret")}

  @impl true
  def handle_event("click", _params, socket) do
    socket
    |> update(:clicks, &(&1 + 1))
    |> push_event("highlight", %{payload: "never stored"})
    |> then(&{:noreply, &1})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p id="clicks">{@clicks}</p>
      <.live_component module={DemoWeb.CounterComponent} id="counter" />
    </div>
    """
  end
end
