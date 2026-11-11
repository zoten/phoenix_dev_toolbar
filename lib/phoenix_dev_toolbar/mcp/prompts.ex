defmodule PhoenixDevToolbar.Mcp.Prompts do
  @moduledoc false
  # MCP prompt definitions (ADR 15). One prompt, `audit_page`. The path is only
  # interpolated into text (never an atom) and length-capped.

  @max_path 2048

  @prompts [
    %{
      "name" => "audit_page",
      "description" =>
        "Audit one page of the running dev app: slow or repeated queries, N+1, errors and oversized LiveView assigns.",
      "arguments" => [
        %{
          "name" => "path",
          "description" => "Exact request path of the page, e.g. \"/posts\".",
          "required" => true
        }
      ]
    }
  ]

  @doc "The prompt definitions for `prompts/list`."
  @spec list() :: [%{String.t() => term()}]
  def list, do: @prompts

  @doc """
  Renders a prompt. `:unknown_prompt` for an unknown name, `{:error, message}`
  for bad arguments (a JSON-RPC invalid params error).
  """
  @spec get(String.t(), term()) ::
          {:ok, %{String.t() => term()}} | {:error, String.t()} | :unknown_prompt
  def get("audit_page", arguments) do
    with {:ok, path} <- path_arg(arguments) do
      {:ok,
       %{
         "description" => "Audit " <> inspect(path),
         "messages" => [
           %{"role" => "user", "content" => %{"type" => "text", "text" => audit_text(path)}}
         ]
       }}
    end
  end

  def get(_name, _arguments), do: :unknown_prompt

  defp path_arg(%{"path" => path}) when is_binary(path) and byte_size(path) > @max_path do
    {:error, "path must be at most #{@max_path} bytes"}
  end

  defp path_arg(%{"path" => path}) when is_binary(path) and path != "", do: {:ok, path}
  defp path_arg(_arguments), do: {:error, "path is required and must be a non-empty string"}

  defp audit_text(path) do
    quoted = inspect(path)

    """
    Audit the page #{quoted} of the running Phoenix dev app with the Phoenix Dev Toolbar tools. Load the page first (a browser, or curl with Accept: text/html) so it is captured.

    1. Call page_summary with path #{quoted}. Note its sid and panel_url.
    2. Call page_n_plus_one with sid set to that sid: repeated queries that should be one query or a preload. Use the sid in every later call, so a reload in between does not switch captures.
    3. Call page_queries with sid set to that sid and sort: "slowest": the slowest queries and where they are called from.
    4. Call page_errors with sid set to that sid: failures during the page's requests and callbacks.
    5. If the page is a LiveView, call page_assigns_shape with path #{quoted} (the page must be open in a browser; not the pinned sid, so a curl capture can fall back to the open tab) and read its note and live_view_sid to know what was read: look for large lists that should be streams.

    Then report the findings, most important first, each with the evidence (query, count, duration, assign name) and a proposed fix, and end with the panel_url so the developer can open the page in the toolbar.

    To check a fix: keep the sid from step 1, change the code, reload the page, then call compare_pages with before set to that sid and recent_errors with since set to that sid.
    """
    |> String.trim_trailing()
  end
end
