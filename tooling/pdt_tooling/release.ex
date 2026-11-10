defmodule PdtTooling.Release do
  @moduledoc false
  # Pure helpers behind `mix bump` (tooling/mix/tasks/bump.ex): the next version,
  # the `@version` line of mix.exs and the CHANGELOG sections. Repository tooling,
  # compiled in dev and test only and never shipped (the package lists lib/ only).

  @unreleased "## [Unreleased]"
  @section ~r/^## \[/m

  @type kind :: :patch | :minor | :major

  @doc """
  The version to release. A version without its tag was never published (the first
  one, 0.0.1, or a run interrupted after the bump): it is released as it is.
  """
  @spec next_version(String.t(), kind(), boolean()) :: {:ok, String.t()} | {:error, String.t()}
  def next_version(current, kind, tagged?) do
    case {Version.parse(current), tagged?} do
      {{:ok, %Version{pre: []} = version}, true} ->
        {:ok, to_string(bump(version, kind))}

      {{:ok, %Version{pre: []}}, false} ->
        {:ok, current}

      {{:ok, _pre_release}, _tagged?} ->
        {:error, "pre-release versions are not supported: #{current}"}

      {:error, _} ->
        {:error, "not a version: #{inspect(current)}"}
    end
  end

  defp bump(version, :patch), do: %{version | patch: version.patch + 1}
  defp bump(version, :minor), do: %{version | minor: version.minor + 1, patch: 0}
  defp bump(version, :major), do: %{version | major: version.major + 1, minor: 0, patch: 0}

  @doc """
  The git tag of a version: the plain version, as Hex publishes it and as the docs'
  `source_ref` expects it.
  """
  @spec tag(String.t()) :: String.t()
  def tag(version), do: version

  @doc "Replaces `@version \"current\"` in mix.exs, exactly once."
  @spec put_version(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def put_version(mix, current, next) do
    line = ~s(@version "#{current}")

    case String.split(mix, line) do
      [before, after_line] -> {:ok, before <> ~s(@version "#{next}") <> after_line}
      [_none] -> {:error, "mix.exs has no #{line}"}
      _many -> {:error, "mix.exs has #{line} more than once"}
    end
  end

  @doc """
  Moves the Unreleased entries into `version`'s section dated `date`, leaving
  Unreleased empty. A section for `version` that already exists (a first release
  written by hand) keeps its body first and takes the new date.
  """
  @spec release_changelog(String.t(), String.t(), Date.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def release_changelog(changelog, version, %Date{} = date) do
    with {:ok, before, unreleased, sections} <- split(changelog),
         {:ok, existing, older} <- take_section(sections, version),
         {:ok, body} <- body(existing, String.trim(unreleased), version) do
      header = "## [#{version}] - #{Date.to_iso8601(date)}"

      released =
        [before <> @unreleased, header, body, String.trim(older)]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      {:ok, released <> "\n"}
    end
  end

  # before (up to the Unreleased header), Unreleased body, released sections.
  defp split(changelog) do
    case String.split(changelog, @unreleased, parts: 2) do
      [before, rest] ->
        {unreleased, sections} = at_next_section(rest)
        {:ok, String.trim_trailing(before) |> with_gap(), unreleased, sections}

      [_none] ->
        {:error, "CHANGELOG.md has no #{@unreleased} section"}
    end
  end

  defp with_gap(""), do: ""
  defp with_gap(before), do: before <> "\n\n"

  defp at_next_section(text) do
    case Regex.run(@section, text, return: :index) do
      [{at, _length}] -> {binary_part(text, 0, at), binary_part(text, at, byte_size(text) - at)}
      nil -> {text, ""}
    end
  end

  # The latest section, when it is `version`'s; a section for it further down is
  # an error (released twice).
  defp take_section(sections, version) do
    header = "## [#{version}]"

    case String.starts_with?(sections, header) do
      true ->
        {body, older} = sections |> after_header_line() |> at_next_section()
        {:ok, String.trim(body), older}

      false ->
        case String.contains?(sections, header) do
          true -> {:error, "CHANGELOG.md already has an older #{header} section"}
          false -> {:ok, "", sections}
        end
    end
  end

  defp after_header_line(section) do
    case String.split(section, "\n", parts: 2) do
      [_header, rest] -> rest
      [_header] -> ""
    end
  end

  defp body("", "", version),
    do: {:error, "nothing to release in #{version}: the #{@unreleased} section is empty"}

  defp body(existing, "", _version), do: {:ok, existing}
  defp body("", unreleased, _version), do: {:ok, unreleased}
  defp body(existing, unreleased, _version), do: {:ok, existing <> "\n" <> unreleased}
end
