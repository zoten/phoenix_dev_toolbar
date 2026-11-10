[
  import_deps: [:phoenix, :phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "{mix,.formatter,.credo,.dialyzer_ignore,dev}.exs",
    "{config,lib,test,examples,tooling}/**/*.{heex,ex,exs}"
  ]
]
