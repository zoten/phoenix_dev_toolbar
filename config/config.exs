import Config

# Library repository config only: not shipped in the Hex package.
if config_env() == :test do
  # LiveView logs every mount at :debug; tests drive real mount telemetry.
  config :logger, level: :warning

  config :phoenix_dev_toolbar, DemoWeb.Endpoint,
    secret_key_base: String.duplicate("pdt-test-secret-key-base-", 4),
    live_view: [signing_salt: "pdt-test-lv-salt"],
    pubsub_server: DemoWeb.PubSub,
    server: false
end
