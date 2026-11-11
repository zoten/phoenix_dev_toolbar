defmodule PhoenixDevToolbar.QueryFrames do
  @moduledoc false
  # Reads a query's stored stacktrace (formatted frames, `Truncate.stacktrace/2`)
  # at read time, never in a telemetry handler (ADR 08):
  #
  #   * `caller/2`: the web-layer frame that led to the query (a LiveView, a
  #     controller, an on_mount hook), where `origin` is the Repo call site.
  #   * `noise/1`: framework queries that run on every dev request
  #     (`Phoenix.Ecto.CheckRepoStatus` and its `schema_migrations` checks),
  #     tagged so the counts leave them out.
  #
  # Frames are strings like `lib/app/x.ex:12: App.X.fun/2` or
  # `anonymous fn/1 in AppWeb.PageLive.mount/3`: no atom is ever created.

  # Callbacks (name/arity) that name the web layer whatever their module.
  @web_callbacks ~w(mount/3 handle_params/3 handle_event/3 handle_info/2 handle_async/3 on_mount/4)
  # Modules that are never the host's code.
  @framework ~w(Phoenix Plug Bandit ThousandIsland Ecto DBConnection Postgrex Exqlite MyXQL
                Task Enum Stream Kernel)
  @noise_frame "Phoenix.Ecto.CheckRepoStatus"

  @typedoc "A module pattern: a `Regex` matched against the module name, or a module name prefix."
  @type pattern :: Regex.t() | String.t()

  @doc "The default `caller_modules:`: a `*Web` namespace, a `*Live` or `*Controller` module."
  @spec default_patterns() :: [pattern()]
  def default_patterns, do: [~r/(\A|\.)\w*Web(\.|\z)/, ~r/(Live|Controller)\z/]

  @doc """
  The first frame (the origin included) of a web module (`patterns`) or of a
  LiveView callback, outside the framework; else the frame after the origin;
  nil without one.
  """
  @spec caller([String.t()], [pattern()]) :: String.t() | nil
  def caller(frames, patterns) when is_list(frames) do
    Enum.find(frames, &web_frame?(&1, patterns)) || Enum.at(frames, 1)
  end

  def caller(_frames, _patterns), do: nil

  @doc """
  `"check_repo_status"` for `Phoenix.Ecto.CheckRepoStatus` queries (a frame of
  it, or SQL on `schema_migrations`), `"framework"` for a stacktrace with no
  frame outside the framework, nil otherwise (no stacktrace: unknown, not noise).
  """
  @spec noise(map()) :: String.t() | nil
  def noise(%{} = data) do
    frames = List.wrap(data[:stacktrace])

    cond do
      check_repo_status?(data[:sql], frames) -> "check_repo_status"
      frames != [] and Enum.all?(frames, &framework_frame?/1) -> "framework"
      true -> nil
    end
  end

  defp check_repo_status?(sql, frames) do
    (is_binary(sql) and String.contains?(sql, "schema_migrations")) or
      Enum.any?(frames, &(is_binary(&1) and String.contains?(&1, @noise_frame)))
  end

  defp web_frame?(frame, patterns) do
    case module_fun(frame) do
      {module, fun} ->
        not framework?(module) and
          (fun in @web_callbacks or Enum.any?(patterns, &matches?(&1, module)))

      nil ->
        false
    end
  end

  defp framework_frame?(frame) do
    case module_fun(frame) do
      {module, _fun} -> framework?(module)
      nil -> false
    end
  end

  defp matches?(%Regex{} = regex, module), do: Regex.match?(regex, module)
  defp matches?(prefix, module) when is_binary(prefix), do: String.starts_with?(module, prefix)
  defp matches?(_other, _module), do: false

  # Erlang modules (`:gen_server`) and the framework namespaces.
  defp framework?(":" <> _erlang), do: true

  defp framework?(module) do
    root = module |> String.split(".", parts: 2) |> hd()
    root in @framework
  end

  # `{module, "function/arity"}` of a formatted frame, nil when it does not parse.
  defp module_fun(frame) when is_binary(frame) do
    mfa = frame |> String.split(": ", parts: 2) |> List.last()

    mfa =
      case String.split(mfa, " in ", parts: 2) do
        [_anonymous, inner] -> inner
        [plain] -> plain
      end

    case Regex.run(~r/\A(.+)\.([^.\/\s]+\/\d+)\z/, mfa) do
      [_all, module, fun] -> {module, fun}
      nil -> nil
    end
  end

  defp module_fun(_frame), do: nil
end
