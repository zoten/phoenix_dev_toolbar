defmodule Mix.Tasks.Bump do
  @shortdoc "Checks, then bumps the version, releases the changelog, commits and tags"

  @moduledoc """
  Prepares a release of this package (repository tooling, never shipped).

      mix bump                    # patch: 0.0.1 -> 0.0.2
      mix bump --version minor    # 0.0.9 -> 0.1.0
      mix bump --skip-ci-min      # without Docker (CI still runs the minimum row)
      mix bump --skip-precommit --skip-ci-min --skip-commit   # files only, to try it

  Steps, stopping at the first failure:

    1. Checks: on `main`, a clean tree, nothing on `origin/main` missing here,
       `PDT_LIVE_VIEW` unset (mix.exs would publish its LiveView requirement)
    2. `mix precommit`, then `agent-tools/ci-min.sh` (the minimum CI row in Docker),
       and the tree still clean after them
    3. The version: when its `<version>` tag does not exist yet it is released as
       it is (the first release, 0.0.1), otherwise it is bumped by `--version`
    4. `@version` in mix.exs, and CHANGELOG.md: the Unreleased entries move into
       the version's section, dated today
    5. A commit (none when no file changed) and an annotated `<version>` tag,
       nothing pushed: `./publish.sh` pushes, waits for CI and publishes to Hex
  """

  use Mix.Task

  alias PdtTooling.Release

  @mix_file "mix.exs"
  @changelog "CHANGELOG.md"
  @switches [
    version: :string,
    skip_precommit: :boolean,
    skip_ci_min: :boolean,
    skip_commit: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    opts = parse!(args)
    kind = kind!(opts[:version] || "patch")
    commit? = not Keyword.get(opts, :skip_commit, false)

    check_repo!(commit?)
    gate!(:precommit, not Keyword.get(opts, :skip_precommit, false), ["mix", "precommit"])
    gate!(:ci_min, not Keyword.get(opts, :skip_ci_min, false), ["agent-tools/ci-min.sh"])
    check_clean!(commit?, "after the checks (they reformat and rebuild the assets)")

    current = Mix.Project.config()[:version]
    version = ok!(Release.next_version(current, kind, tag?(Release.tag(current))))
    tag = Release.tag(version)
    tag?(tag) and Mix.raise("Tag #{tag} already exists")

    write!(@mix_file, &Release.put_version(&1, current, version))
    write!(@changelog, &Release.release_changelog(&1, version, Date.utc_today()))
    Mix.shell().info("Version: #{current} -> #{version}")

    commit_and_tag(commit?, version, tag)
  end

  defp parse!(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} -> opts
      {_opts, rest, invalid} -> Mix.raise("Unknown arguments: #{inspect(rest ++ invalid)}")
    end
  end

  defp kind!("patch"), do: :patch
  defp kind!("minor"), do: :minor
  defp kind!("major"), do: :major
  defp kind!(other), do: Mix.raise("--version #{inspect(other)}: expected patch, minor or major")

  # --skip-commit is a dry run of the file changes: no git requirements.
  defp check_repo!(false), do: :ok

  defp check_repo!(true) do
    case git!(["rev-parse", "--abbrev-ref", "HEAD"]) do
      "main" -> :ok
      branch -> Mix.raise("Release from main, not #{branch}")
    end

    check_clean!(true, "")
    check_env!(System.get_env("PDT_LIVE_VIEW", ""))
    _ = git!(["fetch", "--quiet", "--tags", "origin", "main"])

    case System.cmd("git", ["merge-base", "--is-ancestor", "origin/main", "HEAD"]) do
      {_output, 0} -> :ok
      _behind -> Mix.raise("origin/main has commits missing here: pull first")
    end
  end

  defp check_env!(""), do: :ok

  defp check_env!(value),
    do: Mix.raise("Unset PDT_LIVE_VIEW (#{inspect(value)}): mix.exs would ship that requirement")

  defp check_clean!(false, _when), do: :ok

  defp check_clean!(true, moment) do
    case git!(["status", "--porcelain"]) do
      "" -> :ok
      dirty -> Mix.raise("The working tree is not clean #{moment}:\n#{dirty}")
    end
  end

  defp gate!(_name, false, _command), do: :ok

  defp gate!(name, true, [command | args]) do
    Mix.shell().info("Running #{name}: #{Enum.join([command | args], " ")}")

    case System.cmd(executable!(command), args, into: IO.stream(), stderr_to_stdout: true) do
      {_stream, 0} -> :ok
      {_stream, status} -> Mix.raise("#{name} failed (exit #{status}): fix it before releasing")
    end
  end

  # System.cmd/3 looks a bare name up in PATH but does not resolve a relative path
  # (agent-tools/ci-min.sh): that one is expanded against the project root.
  defp executable!(command) do
    path =
      case String.contains?(command, "/") do
        true -> Path.expand(command, File.cwd!())
        false -> System.find_executable(command)
      end

    case path != nil and File.regular?(path) do
      true -> path
      false -> Mix.raise("#{command} not found")
    end
  end

  defp tag?(tag), do: git!(["tag", "--list", tag]) != ""

  defp write!(path, fun) do
    path |> File.read!() |> fun.() |> ok!() |> then(&File.write!(path, &1))
  end

  defp commit_and_tag(false, version, _tag),
    do:
      Mix.shell().info(
        "Skipped commit and tag: #{@mix_file} and #{@changelog} now say #{version}"
      )

  defp commit_and_tag(true, _version, tag) do
    _ = git!(["add", @mix_file, @changelog])
    :ok = commit(staged?(), tag)
    _ = git!(["tag", "--annotate", tag, "-m", tag])
    Mix.shell().info("Tagged #{tag}, nothing pushed. Next: ./publish.sh")
  end

  # A first release whose section is already dated today changes no file: the tag
  # goes on HEAD, without an empty commit.
  defp commit(false, _tag), do: :ok

  defp commit(true, tag) do
    _ = git!(["commit", "--quiet", "-m", "Release #{tag}"])
    :ok
  end

  defp staged? do
    case System.cmd("git", ["diff", "--cached", "--quiet"]) do
      {_output, 0} -> false
      {_output, _changes} -> true
    end
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, message}), do: Mix.raise(message)

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, _status} -> Mix.raise("git #{Enum.join(args, " ")} failed:\n#{output}")
    end
  end
end
