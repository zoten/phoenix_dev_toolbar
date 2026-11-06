%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "examples/", "dev.exs"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        disabled: [
          # Too noisy for test files where inline module references are common
          {Credo.Check.Design.AliasUsage, []},
          # Explicit last `with` clause keeps the chain readable
          {Credo.Check.Refactor.RedundantWithClauseResult, false}
        ],
        extra: [
          {Jump.CredoChecks.AssertElementSelectorCanNeverFail, []},
          {Jump.CredoChecks.AvoidFunctionLevelElse, []},
          {Jump.CredoChecks.AvoidLoggerConfigureInTest, []},
          {Jump.CredoChecks.AvoidSocketAssignsInTest, []},
          {Jump.CredoChecks.DoctestIExExamples,
           [
             derive_test_path: fn filename ->
               filename
               |> String.replace_leading("lib/", "test/")
               |> String.replace_trailing(".ex", "_test.exs")
             end
           ]},
          {Jump.CredoChecks.ForbiddenFunction,
           functions: [
             {:erlang, :binary_to_term,
              "Use Plug.Crypto.non_executable_binary_to_term/2 instead."},
             {String, :to_atom, "Never create atoms from runtime input (ADR 03)."}
           ]},
          {Jump.CredoChecks.TestHasNoAssertions, []},
          {Jump.CredoChecks.TooManyAssertions, [max_assertions: 20]},
          {Jump.CredoChecks.TopLevelAliasImportRequire, []},
          {Jump.CredoChecks.VacuousTest,
           [
             ignore_setup_only_tests?: true,
             library_modules: [Ecto, Phoenix, Plug]
           ]},
          {Jump.CredoChecks.WeakAssertion, []}
        ]
      }
    }
  ]
}
