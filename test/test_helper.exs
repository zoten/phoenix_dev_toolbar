# The host side of LiveView tests: a PubSub and an endpoint, as a Phoenix app has.
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: DemoWeb.PubSub}], strategy: :one_for_one)
{:ok, _} = DemoWeb.Endpoint.start_link()

ExUnit.start()
