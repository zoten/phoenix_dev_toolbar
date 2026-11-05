defmodule PhoenixDevToolbar.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/zoten/phoenix_dev_toolbar"

  def project do
    [
      app: :phoenix_dev_toolbar,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ],
      name: "PhoenixDevToolbar",
      description: "A dev-only, BEAM-native debug toolbar for Phoenix LiveView applications",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {PhoenixDevToolbar.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, live_view_requirement()},
      {:telemetry, "~> 1.0"},
      {:ecto_sql, "~> 3.12", optional: true},
      {:lazy_html, "~> 0.1", only: :test},
      # Builds priv/static (committed and shipped): never needed by host apps.
      {:esbuild, "~> 0.10", only: :dev, runtime: false},
      # The `mix dev` harness (dev.exs, ADR 06).
      {:ecto_sqlite3, "~> 0.22", only: :dev},
      {:bandit, "~> 1.5", only: :dev},
      {:jason, "~> 1.4", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false}
    ]
  end

  # CI overrides the requirement to test the oldest supported LiveView
  # (PDT_LIVE_VIEW="~> 1.1.0", ADR 06). Unset or empty (GitHub Actions turns a
  # missing matrix value into "") means the published requirement.
  defp live_view_requirement do
    case System.get_env("PDT_LIVE_VIEW", "") do
      "" -> "~> 1.1"
      requirement -> requirement
    end
  end

  defp aliases do
    [
      dev: "run --no-halt dev.exs",
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["esbuild loader", "esbuild panel", "esbuild panel_css"],
      # Unit tests of the loader's pure JS helpers: Node built-ins only (ADR 06).
      "test.js": ["cmd node --test assets/js/test/*.test.mjs"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test --warnings-as-errors",
        "test.js",
        "credo --strict",
        "dialyzer",
        "docs --warnings-as-errors"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv/static .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"],
      # README links to repo files (ADRs, AGENTS.md) that are not part of the docs
      skip_undefined_reference_warnings_on: ["README.md"]
    ]
  end
end
