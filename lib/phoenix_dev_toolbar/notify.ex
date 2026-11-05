defmodule PhoenixDevToolbar.Notify do
  @moduledoc false
  # Live update fan-out through our own Registry (ADR 03). Notifications carry
  # no payload: subscribers read from the Store and throttle their renders.
  # Dispatch is an ETS lookup in the caller, safe on the host's hot path.

  alias PhoenixDevToolbar.Session

  @registry PhoenixDevToolbar.Registry

  @type key :: Session.sid()

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: Registry.child_spec(keys: :duplicate, name: @registry)

  @doc "Subscribes the caller to a session's events and to its child sessions."
  @spec subscribe(key()) :: :ok
  def subscribe(key) do
    {:ok, _owner} = Registry.register(@registry, key, nil)
    :ok
  end

  @spec unsubscribe(key()) :: :ok
  def unsubscribe(key), do: Registry.unregister(@registry, key)

  @doc "Sends `{:pdt_event, sid}` to the subscribers of `sid`."
  @spec event(Session.sid()) :: :ok
  def event(sid), do: dispatch(sid, {:pdt_event, sid})

  @doc """
  Announces a LiveView session with `{:pdt_session, sid}` to the subscribers of
  its parent sid (a new LiveView: first connection or live navigation) and of
  its own sid (a rejoin of a session someone already shows).
  """
  @spec session(Session.t()) :: :ok
  def session(%Session{sid: sid, parent: parent}) do
    message = {:pdt_session, sid}
    maybe_dispatch(parent, message)
    dispatch(sid, message)
  end

  defp maybe_dispatch(nil, _message), do: :ok
  defp maybe_dispatch(key, message), do: dispatch(key, message)

  defp dispatch(key, message) do
    Registry.dispatch(@registry, key, fn entries ->
      for {pid, _value} <- entries, do: send(pid, message)
    end)
  end
end
