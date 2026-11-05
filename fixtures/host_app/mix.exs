defmodule HostApp.MixProject do
  # A minimal host application installing the toolbar exactly as the README
  # says (ADR 01). CI compiles it in :prod, where the dependency does not
  # exist, and in :dev, where it does.
  use Mix.Project

  def project do
    [
      app: :host_app,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:jason, "~> 1.4"},
      {:phoenix_dev_toolbar, path: "../..", only: :dev}
    ]
  end
end
