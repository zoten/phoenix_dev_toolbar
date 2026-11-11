defmodule PhoenixDevToolbar.PageLookup do
  @moduledoc false
  # Resolves "the page" a standalone panel or an MCP tool means (ADR 14).
  # ETS reads only.

  alias PhoenixDevToolbar.Report
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @sid_format ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @doc "True for a well formed sid."
  @spec valid_sid?(term()) :: boolean()
  def valid_sid?(sid) when is_binary(sid), do: Regex.match?(@sid_format, sid)
  def valid_sid?(_other), do: false

  @doc """
  The root sid of the newest page, or nil. Options: `:path` (exact string) or
  `:path_prefix`. A connected mount resolves to its request; a live navigated
  LiveView stays itself.
  """
  @spec newest(keyword()) :: String.t() | nil
  def newest(opts \\ []) do
    case Report.latest(filter(opts)) do
      %{sid: sid} -> root(sid)
      nil -> nil
    end
  end

  @doc """
  The root sid of the page `sid` belongs to: a connected mount (a LiveView whose
  `parent` is a captured request) reads as its request; anything else, a live
  navigated LiveView or an unknown sid, is its own root. The one place of this
  rule (ADR 13, 15).
  """
  @spec root(Session.sid()) :: Session.sid()
  def root(sid) when is_binary(sid) do
    case Store.session(sid) do
      {:ok, %Session{kind: :live_view, parent: parent}} when is_binary(parent) ->
        request_parent(parent, sid)

      _other ->
        sid
    end
  rescue
    # The Store's tables are gone while it restarts.
    ArgumentError -> sid
  end

  @doc "The `Report.sessions/1` options for `:path` / `:path_prefix`."
  @spec filter(keyword()) :: keyword()
  def filter(opts) do
    case {opts[:path], opts[:path_prefix]} do
      {path, _prefix} when is_binary(path) -> [path: path]
      {_path, prefix} when is_binary(prefix) -> [path: ~r/^#{Regex.escape(prefix)}/]
      _none -> []
    end
  end

  defp request_parent(parent, sid) do
    case Store.session(parent) do
      {:ok, %Session{kind: :request}} -> parent
      _other -> sid
    end
  rescue
    # The Store's tables are gone while it restarts.
    ArgumentError -> sid
  end
end
