defmodule PdtTooling.ReleaseTest do
  use ExUnit.Case, async: true

  alias PdtTooling.Release

  @date ~D[2026-11-12]

  describe "next_version/3" do
    test "an untagged version is released as it is" do
      assert Release.next_version("0.0.1", :patch, false) == {:ok, "0.0.1"}
      assert Release.next_version("0.0.1", :minor, false) == {:ok, "0.0.1"}
    end

    test "a tagged version is bumped" do
      assert Release.next_version("0.0.1", :patch, true) == {:ok, "0.0.2"}
      assert Release.next_version("0.0.9", :minor, true) == {:ok, "0.1.0"}
      assert Release.next_version("0.4.2", :major, true) == {:ok, "1.0.0"}
    end

    test "refuses a version it cannot bump" do
      assert {:error, _} = Release.next_version("0.0.1-rc.1", :patch, true)
      assert {:error, _} = Release.next_version("one", :patch, true)
    end
  end

  describe "put_version/3" do
    test "replaces the module attribute once" do
      mix = ~s(  @version "0.0.1"\n  def project, do: [version: @version]\n)

      assert Release.put_version(mix, "0.0.1", "0.0.2") ==
               {:ok, ~s(  @version "0.0.2"\n  def project, do: [version: @version]\n)}
    end

    test "fails when the current version is not there" do
      assert {:error, _} = Release.put_version(~s(@version "9.9.9"\n), "0.0.1", "0.0.2")
    end
  end

  describe "release_changelog/3" do
    test "moves the unreleased entries into a new section and empties Unreleased" do
      changelog = """
      # Changelog

      ## [Unreleased]

      - Feature two (ADR 05)
      - Fix one (ADR 03)

      ## [0.0.1] - 2026-11-10

      - Feature one (ADR 01)
      """

      assert {:ok, released} = Release.release_changelog(changelog, "0.0.2", @date)

      assert released == """
             # Changelog

             ## [Unreleased]

             ## [0.0.2] - 2026-11-12

             - Feature two (ADR 05)
             - Fix one (ADR 03)

             ## [0.0.1] - 2026-11-10

             - Feature one (ADR 01)
             """
    end

    test "an existing section for the version keeps its body first and takes today's date" do
      changelog = """
      # Changelog

      ## [Unreleased]

      - Late fix (ADR 03)

      ## [0.0.1] - 2026-11-10

      First public release.

      - Feature one (ADR 01)
      """

      assert {:ok, released} = Release.release_changelog(changelog, "0.0.1", @date)

      assert released == """
             # Changelog

             ## [Unreleased]

             ## [0.0.1] - 2026-11-12

             First public release.

             - Feature one (ADR 01)
             - Late fix (ADR 03)
             """
    end

    test "an existing section with nothing unreleased only takes today's date" do
      changelog = "## [Unreleased]\n\n## [0.0.1] - 2026-11-10\n\n- Feature one\n"

      assert Release.release_changelog(changelog, "0.0.1", @date) ==
               {:ok, "## [Unreleased]\n\n## [0.0.1] - 2026-11-12\n\n- Feature one\n"}
    end

    test "refuses a release with nothing in it" do
      changelog = "## [Unreleased]\n\n## [0.0.1] - 2026-11-10\n\n- Feature one\n"

      assert {:error, message} = Release.release_changelog(changelog, "0.0.2", @date)
      assert message =~ "Unreleased"
    end

    test "refuses a changelog without an Unreleased section" do
      assert {:error, _} = Release.release_changelog("# Changelog\n", "0.0.2", @date)
    end
  end

  describe "tag/1" do
    test "matches the docs source_ref" do
      assert Release.tag("0.0.1") == "v0.0.1"
    end
  end
end
