defmodule PhoenixDevToolbar.PageHelpers do
  @moduledoc false
  # Host pages loaded as a browser would (DemoWeb.Endpoint), and the toolbar's
  # plugins attached for a test.

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  import PhoenixDevToolbar.EnvHelpers, only: [put_app_env: 2]

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Store

  @endpoint DemoWeb.Endpoint

  @doc "What a browser sends when it loads a page: `accept` and `sec-fetch-dest: document`."
  @spec browser_headers(Plug.Conn.t()) :: Plug.Conn.t()
  def browser_headers(conn \\ build_conn()) do
    conn
    |> Plug.Conn.put_req_header("accept", "text/html")
    |> Plug.Conn.put_req_header("sec-fetch-dest", "document")
  end

  @doc "Dead renders `path` with a browser's page headers: the conn and the injected sid."
  @spec load_page(Plug.Conn.t(), String.t()) :: {Plug.Conn.t(), String.t()}
  def load_page(conn \\ build_conn(), path) do
    conn = conn |> browser_headers() |> get(path)

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
  def open_panel(sid, opts \\ []) when is_binary(sid), do: open_panel_at("?sid=#{sid}", opts)

  @doc """
  Connects the panel LiveView at `query`, a query string such as
  `"?path=/users"` or `""` (the newest page). `:conn` as for `open_panel/2`.
  """
  @spec open_panel_at(String.t(), keyword()) :: struct()
  def open_panel_at(query, opts \\ []) when is_binary(query) do
    conn = Keyword.get_lazy(opts, :conn, &build_conn/0)
    {:ok, panel, _html} = live(conn, "/__pdt/panel" <> query)
    panel
  end

  @doc "Clicks the tab `id` (the panel loads a tab's rows when it opens, ADR 04)."
  @spec open_panel_tab(struct(), String.t()) :: String.t() | {:error, term()}
  def open_panel_tab(view, id) do
    view |> element("#pdt-tab-#{id}") |> render_click()
  end

  @doc """
  Loads `path` (or takes a `sid`), connects its panel and opens the tab `tab`.
  `:conn` as for `open_panel/2`; `visible: true` also reports the panel shown.
  """
  @spec open_tab(String.t(), String.t(), keyword()) :: struct()
  def open_tab(path_or_sid, tab, opts \\ []) do
    sid = sid_of(path_or_sid)
    panel = open_panel(sid, Keyword.take(opts, [:conn]))
    _ = open_panel_tab(panel, tab)
    _ = if opts[:visible], do: visible(panel)
    panel
  end

  defp sid_of("/" <> _rest = path) do
    {_host, sid} = visit(path)
    sid
  end

  defp sid_of(sid), do: sid

  @doc "The panel reports itself open and visible (`pdt:visibility`)."
  @spec visible(struct()) :: String.t() | {:error, term()}
  def visible(panel),
    do: render_hook(panel, "pdt:visibility", %{"open" => true, "visible" => true})

  @doc "The panel reports itself open and hidden (`pdt:visibility`)."
  @spec hidden(struct()) :: String.t() | {:error, term()}
  def hidden(panel),
    do: render_hook(panel, "pdt:visibility", %{"open" => true, "visible" => false})

  @doc "Hides and shows the panel again, which reads what it shows at once."
  @spec reshow(struct()) :: String.t() | {:error, term()}
  def reshow(panel) do
    _ = hidden(panel)
    visible(panel)
  end

  @doc """
  The values of attribute `name` of the elements matching `selector` in the
  rendered view, in document order.
  """
  @spec attribute(struct(), String.t(), String.t()) :: [String.t()]
  def attribute(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
  end

  @doc "Runs `sql` with `params` in the host LiveView and has the panel handle the query."
  @spec run_sqlite(struct(), struct(), String.t(), list()) :: String.t() | {:error, term()}
  def run_sqlite(host, panel, sql, params \\ []) do
    render_hook(host, "sqlite", %{"sql" => sql, "params" => params})
    flush(panel)
  end

  @doc """
  The seqs of the Ecto tab's query rows, in order; only the rows whose text
  contains `matching` (all by default).
  """
  @spec query_row_seqs(struct(), String.t()) :: [String.t()]
  def query_row_seqs(panel, matching \\ "") do
    panel
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#pdt-queries li[id^=pdt-query-]")
    |> Enum.filter(&(LazyHTML.text(&1) =~ matching))
    |> Enum.map(fn row ->
      "pdt-query-" <> seq = row |> LazyHTML.attribute("id") |> hd()
      seq
    end)
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

  @doc """
  The seqs the panel LiveView remembers having shown, per sid. A private assign
  of `PhoenixDevToolbar.PanelLive`, read from the LiveView process state
  (Phoenix LiveView 1.2.13: `socket.assigns`). Isolated here on purpose.
  """
  @spec panel_seen(struct()) :: %{String.t() => MapSet.t(non_neg_integer())}
  def panel_seen(view), do: :sys.get_state(view.pid).socket.assigns.seen

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
    with_plugins([
      {PhoenixDevToolbar.Plugins.Ecto, repos: [DemoWeb.SQLiteRepo]},
      PhoenixDevToolbar.Plugins.LiveView
    ])
  end

  @doc """
  Resets the Store and attaches exactly `plugins` for this test; on exit the
  configured plugins are attached again and the Store reset. `env` is
  application env set before the attach; on exit it is restored before the
  configured plugins are attached again, so they read the original env.
  """
  @spec with_plugins([module() | PhoenixDevToolbar.Config.entry()], keyword()) :: :ok
  def with_plugins(plugins, env \\ []) do
    ExUnit.Callbacks.on_exit(fn ->
      attach_plugins()
      Store.reset()
    end)

    Enum.each(env, fn {key, value} -> put_app_env(key, value) end)
    Store.reset()
    Collector.attach(plugins)
  end

  @doc "`with_plugins/2` with the configured plugins followed by `extra`."
  @spec with_configured_plugins([module() | PhoenixDevToolbar.Config.entry()], keyword()) :: :ok
  def with_configured_plugins(extra \\ [], env \\ []) do
    with_plugins(PhoenixDevToolbar.Application.plugins() ++ extra, env)
  end

  @doc "Attaches the configured plugins followed by `extra`."
  @spec attach_plugins([module() | PhoenixDevToolbar.Config.entry()]) :: :ok
  def attach_plugins(extra \\ []) do
    Collector.attach(PhoenixDevToolbar.Application.plugins() ++ extra)
  end
end
