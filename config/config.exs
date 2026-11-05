import Config

# Library repository config only: not shipped in the Hex package.
if config_env() == :test do
  # LiveView logs every mount at :debug; tests drive real mount telemetry.
  config :logger, level: :warning
end
