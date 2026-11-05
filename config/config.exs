import Config

# Library repository config only: not shipped in the Hex package.

if config_env() == :dev do
  # `mix assets.build` writes the committed bundles in priv/static (ADR 04).
  # NODE_PATH lets panel.js import the phoenix and phoenix_live_view JS from deps.
  assets = Path.expand("../assets", __DIR__)
  common = ~w(--bundle --minify --target=es2020 --format=iife)

  config :esbuild,
    version: "0.25.10",
    loader: [args: ["js/loader.js", "--outfile=../priv/static/loader.js" | common], cd: assets],
    panel: [
      args: ["js/panel.js", "--outfile=../priv/static/panel.js" | common],
      cd: assets,
      env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
    ],
    panel_css: [
      args: ~w(css/panel.css --bundle --minify --outfile=../priv/static/panel.css),
      cd: assets
    ]
end

if config_env() == :test do
  # LiveView logs every mount at :debug; tests drive real mount telemetry.
  config :logger, level: :warning

  config :phoenix_dev_toolbar, DemoWeb.Endpoint,
    secret_key_base: String.duplicate("pdt-test-secret-key-base-", 4),
    live_view: [signing_salt: "pdt-test-lv-salt"],
    pubsub_server: DemoWeb.PubSub,
    server: false
end
