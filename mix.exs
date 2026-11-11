defmodule PhoenixDevToolbar.MixProject do
  use Mix.Project

  @version "0.0.4"
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
        flags: [:unmatched_returns, :error_handling, :extra_return, :missing_return],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true,
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

  # The example plugins are compiled in tests (and loaded by dev.exs), and the
  # release tooling (`mix bump`) in dev and tests: never shipped, the package only
  # lists lib/. Host apps compile this dependency in :prod, so lib/ alone.
  defp elixirc_paths(:test), do: ["lib", "test/support", "examples", "tooling"]
  defp elixirc_paths(:dev), do: ["lib", "tooling"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:telemetry, "~> 1.0"},
      # The panel's own socket (ADR 04); already a Phoenix dependency.
      {:websock_adapter, "~> 0.5"},
      {:ecto_sql, "~> 3.12", optional: true},
      {:lazy_html, "~> 0.1", only: :test},
      # Builds priv/static (committed and shipped): never needed by host apps.
      {:esbuild, "~> 0.10", only: :dev, runtime: false},
      # The `mix dev` harness (dev.exs, ADR 06) and the EXPLAIN tests (ADR 08).
      {:ecto_sqlite3, "~> 0.22", only: [:dev, :test]},
      # The Postgres EXPLAIN tests, run when PDT_POSTGRES_URL is set (ADR 08).
      {:postgrex, "~> 0.20", only: :test},
      # The example plugin (examples/oban, ADR 05): never needed by host apps.
      {:oban, "~> 2.19", only: [:dev, :test]},
      # The harness server, and the panel socket's end to end test (ADR 04).
      {:bandit, "~> 1.5", only: [:dev, :test]},
      {:jason, "~> 1.4", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      dev: "run --no-halt dev.exs",
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["esbuild loader", "esbuild panel", "esbuild panel_css"],
      # JS tests: pure helpers, plus loader/panel wiring on a fake DOM. Node built-ins only (ADR 06).
      "test.js": ["cmd node --test assets/js/test/*.test.mjs"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test --warnings-as-errors",
        "test.js",
        # priv/static is committed and shipped: rebuild and fail on a stale bundle (ADR 04).
        # esbuild is a dev only dependency, hence the MIX_ENV=dev subprocess.
        "cmd env MIX_ENV=dev mix assets.build",
        "cmd git diff --exit-code priv/static",
        "credo --strict",
        "dialyzer",
        "docs --warnings-as-errors"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"},
      files:
        ~w(lib priv/static .formatter.exs mix.exs README.md LICENSE CHANGELOG.md usage-rules.md usage-rules)
    ]
  end

  defp docs do
    [
      main: "readme",
      # README images: copied into the docs (hexdocs), never into the package files
      assets: %{"media" => "media"},
      source_ref: @version,
      extras: [
        "README.md",
        "guides/agent-setup.md",
        "guides/writing-a-plugin.md",
        "CHANGELOG.md",
        "SECURITY.md"
      ],
      groups_for_extras: [Guides: ["guides/agent-setup.md", "guides/writing-a-plugin.md"]],
      # Examples and the release tooling are compiled in dev and tests, where the
      # docs are built: neither belongs in them.
      filter_modules: fn module, _meta ->
        not String.starts_with?(inspect(module), ["PdtExamples", "PdtTooling", "Mix.Tasks."])
      end,
      groups_for_modules: [
        Setup: [PhoenixDevToolbar, PhoenixDevToolbar.Plug],
        "Built-in plugins": [
          PhoenixDevToolbar.Plugins.Ecto,
          PhoenixDevToolbar.Plugins.Request,
          PhoenixDevToolbar.Plugins.LiveView,
          PhoenixDevToolbar.Plugins.Process,
          PhoenixDevToolbar.Plugins.System,
          PhoenixDevToolbar.Plugins.Cluster,
          PhoenixDevToolbar.Plugins.Eval
        ],
        "Reading data": [PhoenixDevToolbar.Report],
        "Plugin API": [
          PhoenixDevToolbar.Plugin,
          PhoenixDevToolbar.Panel,
          PhoenixDevToolbar.Context,
          PhoenixDevToolbar.Event,
          PhoenixDevToolbar.Truncate
        ]
      ]
    ]
  end
end
