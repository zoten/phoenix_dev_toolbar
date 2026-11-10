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
  Connects the panel LiveView for `sid`. `:conn` is the conn to connect with
  (default `build_conn()`, e.g. for a custom `peer_data`).
  """
  @spec open_panel(String.t(), keyword()) :: struct()
  def open_panel(sid, opts \\ []) do
    conn = Keyword.get_lazy(opts, :conn, &build_conn/0)
    {:ok, panel, _html} = live(conn, "/__pdt/panel?sid=#{sid}")
    panel
  end

  @doc """
  Has the panel handle everything the Store sent it (`:pdt_flush`) and renders.
  """
  @spec flush(struct()) :: String.t() | {:error, term()}
  def flush(view) do
    send(view.pid, :pdt_flush)
    render(view)
  end

  @doc """
  Delivers the pending `kind` timer tick of the panel component `module` with
  DOM id `id` right away, with its real token, instead of waiting for the timer.
  The token is private to the component, so this reads it from the LiveView
  process state (Phoenix LiveView 1.2.13: `components` is
  `{cid_to_component, ...}` with `{module, id, assigns, ...}` values). Isolated
  here on purpose; configure the tab's interval high so the real timer cannot race.
  """
  @spec tick_now(struct(), module(), String.t(), atom()) :: String.t() | {:error, term()}
  def tick_now(view, module, id, kind) do
    {cid_to_component, _id_to_cid, _uuids} = :sys.get_state(view.pid).components

    {_cid, {_module, ^id, assigns, _private, _prints}} =
      Enum.find(cid_to_component, fn {_cid, component} -> elem(component, 1) == id end)

    {_ref, token} = Map.fetch!(assigns.timers, kind)
    PhoenixDevToolbar.Panel.send_now(view.pid, module, id, {kind, token})
    render(view)
  end

  @doc "Milliseconds as native time units (event timestamps)."
  @spec ms(integer()) :: integer()
  def ms(n), do: System.convert_time_unit(n, :millisecond, :native)

  @doc """
  ExUnit setup for the Ecto tab on real SQLite queries: the Store reset, the Ecto
  plugin on `DemoWeb.SQLiteRepo`, `/demo` visited and its panel connected.
  Restores the plugins and the Store on exit.
  """
  @spec sqlite_panel(map()) :: %{host: struct(), panel: struct()}
  def sqlite_panel(context) do
    :ok = sqlite_plugins(context)
    {host, sid} = visit("/demo")
    %{host: host, panel: open_panel(sid)}
  end

  @doc """
  ExUnit setup for real SQLite queries: the Store reset, the Ecto plugin on
  `DemoWeb.SQLiteRepo` and the LiveView plugin. Restores both on exit.
  """
  @spec sqlite_plugins(map()) :: :ok
  def sqlite_plugins(_context) do
    PhoenixDevToolbar.Store.reset()

    Collector.attach([
      {PhoenixDevToolbar.Plugins.Ecto, repos: [DemoWeb.SQLiteRepo]},
      PhoenixDevToolbar.Plugins.LiveView
    ])

    ExUnit.Callbacks.on_exit(fn ->
      attach_plugins()
      PhoenixDevToolbar.Store.reset()
    end)

    :ok
  end

  @doc "Attaches the configured plugins followed by `extra`."
  @spec attach_plugins([module() | PhoenixDevToolbar.Config.entry()]) :: :ok
  def attach_plugins(extra \\ []) do
    Collector.attach(PhoenixDevToolbar.Application.plugins() ++ extra)
  end
end
