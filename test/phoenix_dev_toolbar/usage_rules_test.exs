defmodule PhoenixDevToolbar.UsageRulesTest do
  # The shipped usage rules and agent skill (ADR 13) only name Report
  # functions that exist, and the package ships them.
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.Report

  @files ["usage-rules.md", "usage-rules/skills/phoenix-dev-toolbar-report/SKILL.md"]

  test "the usage rules and the skill name existing Report functions, with skill frontmatter" do
    exported = Report.__info__(:functions) |> Keyword.keys() |> MapSet.new(&Atom.to_string/1)

    named =
      for file <- @files,
          [_, name] <- Regex.scan(~r/Report\.([a-z_?]+)/, File.read!(file)),
          uniq: true,
          do: name

    assert named != []
    assert Enum.reject(named, &MapSet.member?(exported, &1)) == []

    # The frontmatter usage_rules copies into the host's skills folder.
    [_, frontmatter] = Regex.run(~r/\A---\n(.*?)\n---\n/s, File.read!(List.last(@files)))
    assert frontmatter =~ ~r/^name: phoenix-dev-toolbar-report$/m
    assert frontmatter =~ ~r/^description: ".+"$/m
  end

  test "the package ships the usage rules" do
    files = Mix.Project.config()[:package][:files]
    assert "usage-rules.md" in files and "usage-rules" in files
  end
end
