locals_without_parens = [dev_toolbar: 1, dev_toolbar: 2]

[
  import_deps: [:phoenix, :phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["{mix,.formatter,.credo,dev}.exs", "{config,lib,test}/**/*.{heex,ex,exs}"],
  locals_without_parens: locals_without_parens,
  # Host apps get `dev_toolbar "/__pdt"` without parens via import_deps.
  export: [locals_without_parens: locals_without_parens]
]
