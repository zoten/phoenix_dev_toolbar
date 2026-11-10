%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "examples/", "tooling/", "dev.exs"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        disabled: [
          # Too noisy for Phoenix style code and test files where inline module
          # references are common
          {Credo.Check.Design.AliasUsage, []},
          # Explicit last `with` clause keeps the chain readable
          {Credo.Check.Refactor.RedundantWithClauseResult, false}
        ],
        extra: [
          # Opt-in Credo checks: off by default, on here.
          {Credo.Check.Design.DuplicatedCode, []},
          {Credo.Check.Readability.ImplTrue, []},
          {Credo.Check.Refactor.AppendSingleItem, []},
          {Credo.Check.Refactor.NegatedIsNil, []},
          # Tests build atom keys from literal ranges; the rule is about runtime input.
          {Credo.Check.Warning.UnsafeToAtom, files: %{excluded: ["test/"]}},
          {Jump.CredoChecks.AssertElementSelectorCanNeverFail, []},
          {Jump.CredoChecks.AvoidFunctionLevelElse, []},
          {Jump.CredoChecks.AvoidLoggerConfigureInTest, []},
          # Default exclusion list is empty
          {Jump.CredoChecks.AvoidSocketAssignsInTest, []},
          {Jump.CredoChecks.DoctestIExExamples,
           [
             # Tells Credo where to look for the `doctest` call.
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
          {Jump.CredoChecks.LiveViewFormCanBeRehydrated, []},
          # Ecto migrations only (none here today); default start_after is "0"
          {Jump.CredoChecks.PreferTextColumns, []},
          {Jump.CredoChecks.TestHasNoAssertions, []},
          # Default max_assertions is 20
          {Jump.CredoChecks.TooManyAssertions, [max_assertions: 20]},
          {Jump.CredoChecks.TopLevelAliasImportRequire, []},
          {Jump.CredoChecks.VacuousTest,
           [
             # When true (default), tests that destructure setup context
             # (3-arity test blocks) are considered not vacuous.
             ignore_setup_only_tests?: true,
             # Library namespaces whose calls do not count as production code
             library_modules: [Ecto, Jason, Oban, Phoenix, Plug]
           ]},
          {Jump.CredoChecks.WeakAssertion, []}
        ]
      }
    }
  ]
}
