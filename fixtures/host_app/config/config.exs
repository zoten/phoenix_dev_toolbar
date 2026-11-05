import Config

config :host_app, HostApp.Endpoint,
  secret_key_base: String.duplicate("host-app-fixture-secret-", 4),
  live_view: [signing_salt: "host-app-fixture"]

# What `mix phx.new` generates for dev only.
if config_env() == :dev do
  config :host_app, dev_routes: true
  config :host_app, HostApp.Endpoint, code_reloader: true
  config :phoenix_dev_toolbar, plugins: [:defaults, HostApp.Toolbar.Greetings]
end
