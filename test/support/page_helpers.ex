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

  @doc """
  ExUnit setup for the Ecto tab on real SQLite queries: the Store reset, the Ecto
  plugin on `DemoWeb.SQLiteRepo`, `/demo` visited and its panel connected.
  Restores the plugins and the Store on exit.
  """
  @spec sqlite_panel(map()) :: %{host: struct(), panel: struct()}
  def sqlite_panel(_context) do
    PhoenixDevToolbar.Store.reset()

    Collector.attach([
      {PhoenixDevToolbar.Plugins.Ecto, repos: [DemoWeb.SQLiteRepo]},
      PhoenixDevToolbar.Plugins.LiveView
    ])

    ExUnit.Callbacks.on_exit(fn ->
      attach_plugins()
      PhoenixDevToolbar.Store.reset()
    end)

    {host, sid} = visit("/demo")
    {:ok, panel, _html} = live(build_conn(), "/__pdt/panel?sid=#{sid}")
    %{host: host, panel: panel}
  end

  @doc "Attaches the configured plugins followed by `extra`."
  @spec attach_plugins([module() | PhoenixDevToolbar.Config.entry()]) :: :ok
  def attach_plugins(extra \\ []) do
    Collector.attach(PhoenixDevToolbar.Application.plugins() ++ extra)
  end
end
