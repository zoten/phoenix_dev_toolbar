import Config

# Library repository config only: not shipped in the Hex package.

if config_env() == :dev do
  # `mix assets.build` writes the committed bundles in priv/static (ADR 04).
  assets = Path.expand("../assets", __DIR__)
  common = ~w(--bundle --minify --target=es2020 --format=iife)

  config :esbuild,
    version: "0.25.10",
    loader: [args: ["js/loader.js", "--outfile=../priv/static/loader.js" | common], cd: assets],
    # Phoenix and LiveView are not bundled: the panel loads the host's own clients.
    panel: [args: ["js/panel.js", "--outfile=../priv/static/panel.js" | common], cd: assets],
    panel_css: [
      args: ~w(css/panel.css --bundle --minify --outfile=../priv/static/panel.css),
      cd: assets
    ]
end

if config_env() == :test do
  # LiveView logs every mount at :debug; tests drive real mount telemetry.
  config :logger, level: :warning

  # Process actions are opt-in (ADR 10): the suite runs them for loopback clients;
  # the default-off tests delete the key.
  config :phoenix_dev_toolbar, actions: :loopback

  # Mix.env() is :test here, not :dev: enable explicitly (ADR 01).
  config :phoenix_dev_toolbar, enabled: true

  # No automatic TTL sweep mid-test: sessions dated at the epoch would expire.
  # Tests call Store.sweep/1 explicitly.
  config :phoenix_dev_toolbar, limits: [sweep_ms: :timer.hours(24)]

  # The suite's canonical repo (test_helper.exs), so plugins start without the
  # "no Ecto repos" warning; tests of other repos override it and restore it.
  config :phoenix_dev_toolbar, repos: [DemoWeb.SQLiteRepo]

  # Phoenix.ConnTest's host: listed, as a host app lists its own (HostCheck).
  config :phoenix_dev_toolbar, allowed_hosts: ["www.example.com"]

  config :phoenix_dev_toolbar, DemoWeb.Endpoint,
    secret_key_base: String.duplicate("pdt-test-secret-key-base-", 4),
    live_view: [signing_salt: "pdt-test-lv-salt"],
    pubsub_server: DemoWeb.PubSub,
    server: false

  config :phoenix_dev_toolbar, PhoenixDevToolbar.OriginEndpoint,
    secret_key_base: String.duplicate("pdt-test-secret-key-base-", 4),
    pubsub_server: DemoWeb.PubSub,
    server: false
end
