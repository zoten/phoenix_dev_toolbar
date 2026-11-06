defmodule PhoenixDevToolbar.PageHelpers do
  @moduledoc false
  # Host pages loaded as a browser would (DemoWeb.Endpoint), and the toolbar's
  # plugins attached for a test.

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhoenixDevToolbar.Collector

  @endpoint DemoWeb.Endpoint

  @doc "Dead renders `path` with a browser's page headers: the conn and the injected sid."
  @spec load_page(Plug.Conn.t(), String.t()) :: {Plug.Conn.t(), String.t()}
  def load_page(conn \\ build_conn(), path) do
    conn =
      conn
      |> Plug.Conn.put_req_header("accept", "text/html")
      |> Plug.Conn.put_req_header("sec-fetch-dest", "document")
      |> get(path)

    [sid] =
      conn
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("script[data-pdt-sid]")
      |> LazyHTML.attribute("data-pdt-sid")

    {conn, sid}
  end

  @doc "Loads `path` and connects its LiveView: the host LiveView and the page's sid."
  # The host is a Phoenix.LiveViewTest.View, which defines no type.
  @spec visit(Plug.Conn.t(), String.t()) :: {struct(), String.t()}
  def visit(conn \\ build_conn(), path) do
    {conn, sid} = load_page(conn, path)
    {:ok, host, _html} = live(conn)
    {host, sid}
  end

  @doc "Attaches the configured plugins followed by `extra`."
  @spec attach_plugins([module() | PhoenixDevToolbar.Config.entry()]) :: :ok
  def attach_plugins(extra \\ []) do
    Collector.attach(PhoenixDevToolbar.Application.plugins() ++ extra)
  end
end
