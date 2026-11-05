defmodule PhoenixDevToolbar.Notify do
  @moduledoc false
  # Live update fan-out through our own Registry (ADR 03). Notifications carry
  # no payload: subscribers read from the Store and throttle their renders.
  # Dispatch is an ETS lookup in the caller, safe on the host's hot path.

  alias PhoenixDevToolbar.Session

  @registry PhoenixDevToolbar.Registry

  @type key :: Session.sid() | {:transport, pid()}

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: Registry.child_spec(keys: :duplicate, name: @registry)

  @doc "Subscribes the caller to a session's events or to a transport's new sessions."
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
  Announces a new LiveView session with `{:pdt_session, sid}` to the subscribers
  of its parent sid (dead render to LiveView) and of its transport (live
  navigation in the same tab).
  """
  @spec session(Session.t()) :: :ok
  def session(%Session{sid: sid, parent: parent, transport: transport}) do
    message = {:pdt_session, sid}
    maybe_dispatch(parent, message)
    maybe_dispatch(transport && {:transport, transport}, message)
  end

  defp maybe_dispatch(nil, _message), do: :ok
  defp maybe_dispatch(key, message), do: dispatch(key, message)

  defp dispatch(key, message) do
    Registry.dispatch(@registry, key, fn entries ->
      for {pid, _value} <- entries, do: send(pid, message)
    end)
  end
end
