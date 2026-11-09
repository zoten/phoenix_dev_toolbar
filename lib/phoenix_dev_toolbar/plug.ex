defmodule PhoenixDevToolbar.Plug do
  @moduledoc """
  The whole toolbar integration: tracks page requests, injects the toolbar
  into HTML responses, and serves the toolbar's own assets and panel.

  Add it to your endpoint, next to `Phoenix.LiveReloader`:

      if code_reloading? do
        plug PhoenixDevToolbar.Plug
      end

  No router changes are needed: the panel is a LiveView rendered by this plug
  under `:path`, connected through your existing LiveView socket. This keeps
  the package installable with `only: :dev`, since nothing outside the
  `code_reloading?` block references it.

  ## Options

    * `:path` - where the toolbar lives. Defaults to `"/__pdt"`.
    * `:nonce_assign` - the `conn.assigns` key holding a CSP nonce for the
      injected script tag. Defaults to `:csp_nonce`.

  The plug does nothing when the toolbar is disabled
  (`config :phoenix_dev_toolbar, enabled: false`).
  """

  @behaviour Plug

  require Logger

  alias PhoenixDevToolbar.Attribution
  alias PhoenixDevToolbar.Config
  alias PhoenixDevToolbar.EctoExport
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.HostCheck
  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.PanelSocket
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store
  alias Plug.Conn

  @default_path "/__pdt"
  # Served name => {application, file under its priv/static, content type}. The
  # Phoenix and LiveView clients are the host's own installed builds, so the
  # panel's JS always matches the host's server versions (ADR 04).
  @assets %{
    "loader.js" => {:phoenix_dev_toolbar, "loader.js", "text/javascript"},
    "panel.js" => {:phoenix_dev_toolbar, "panel.js", "text/javascript"},
    "panel.css" => {:phoenix_dev_toolbar, "panel.css", "text/css"},
    "phoenix.js" => {:phoenix, "phoenix.min.js", "text/javascript"},
    "live_view.js" => {:phoenix_live_view, "phoenix_live_view.min.js", "text/javascript"}
  }
  # Other HTML documents that must never get a toolbar of their own.
  @skip_prefixes [["phoenix", "live_reload"]]

  # `:live_socket_path` is gone (ADR 04: the panel has its own socket). Once per
  # VM: init/1 runs on every request with `plug_init_mode: :runtime` (dev).
  defp warn_removed(opts) do
    key = {PhoenixDevToolbar.Plug, :live_socket_path}

    if Keyword.has_key?(opts, :live_socket_path) and :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)

      Logger.warning(
        "[phoenix_dev_toolbar] the :live_socket_path option is gone and is ignored: " <>
          "the panel connects through its own socket"
      )
    end
  end

  @impl Plug
  def init(opts) do
    warn_removed(opts)
    path = opts |> Keyword.get(:path, @default_path) |> String.trim_trailing("/")
    segments = String.split(path, "/", trim: true)

    case {path, segments} do
      {"/" <> _, [_ | _]} ->
        %{
          path: path,
          segments: segments,
          nonce_assign: Keyword.get(opts, :nonce_assign, :csp_nonce)
        }

      _ ->
        raise ArgumentError,
              "PhoenixDevToolbar.Plug :path must be an absolute path below the root, " <>
                "such as \"/__pdt\", got: #{inspect(path)}"
    end
  end

  @impl Plug
  def call(%Conn{} = conn, opts) do
    case PhoenixDevToolbar.enabled?() do
      true -> route(conn, opts)
      false -> conn
    end
  end

  defp route(conn, %{segments: segments} = opts) do
    case strip_prefix(conn.path_info, segments) do
      {:ok, ["assets", file]} ->
        serve_asset(conn, file)

      {:ok, ["panel"]} ->
        guarded(conn, opts, &serve_panel(&1, opts))

      # The Ecto tab's Download (ADR 08): same origin, so a host's frame-src allows it.
      {:ok, ["export", "ecto.json"]} ->
        guarded(conn, nil, &serve_export/1)

      # The panel's own LiveView socket (ADR 04): no host socket, no host token.
      {:ok, ["live", "websocket"]} ->
        guarded(conn, nil, &(&1 |> untracked() |> PanelSocket.upgrade()))

      # Anything else under our path is not ours to answer: never tracked.
      {:ok, _rest} ->
        untracked(conn)

      :error ->
        maybe_track(conn, opts)
    end
  end

  # DNS rebinding guard (ADR 04, HostCheck): the panel, its socket and the export
  # answer only for a Host that cannot be rebound.
  defp guarded(conn, opts, serve) do
    case HostCheck.allowed?(conn) do
      true ->
        serve.(conn)

      false ->
        HostCheck.log_refused(conn.host)
        conn |> untracked() |> refuse(opts) |> Conn.halt()
    end
  end

  # The panel is the toolbar's iframe: the refusal shows there, as a bar in the
  # panel's own style that says what to add. The socket and the export get text.
  defp refuse(conn, %{path: path}) do
    host = conn.host |> String.slice(0, 100) |> Plug.HTML.html_escape()

    conn
    |> Conn.put_resp_content_type("text/html")
    |> Conn.put_resp_header("content-security-policy", "frame-ancestors 'self'")
    |> Conn.put_resp_header("x-content-type-options", "nosniff")
    |> Conn.send_resp(403, """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>dev toolbar</title>
    <link rel="stylesheet" href="#{Plug.HTML.html_escape(path)}/assets/panel.css"></head>
    <body class="pdt"><div class="pdt-header" id="pdt-refused">
    <span class="pdt-logo">dev toolbar</span>
    <span class="pdt-hint">Off for the host #{host}: if it is yours, add it to
    <code>allowed_hosts: ["#{host}"]</code> in the toolbar config (a DNS rebinding guard).</span>
    </div></body></html>
    """)
  end

  defp refuse(conn, _opts) do
    conn
    |> Conn.put_resp_content_type("text/plain")
    |> Conn.send_resp(
      403,
      "phoenix_dev_toolbar: this host is not allowed to open the panel. If it is yours, " <>
        "add it to `allowed_hosts:` in the toolbar config (a DNS rebinding guard)."
    )
  end

  ## Panel

  # Rendered without a router (`live_render/3`): the panel LiveView gets the
  # sid through its session, never through route params. The host's session
  # plug usually runs after this one, so nothing here needs the cookie session.
  defp serve_panel(%Conn{method: "GET"} = conn, opts) do
    conn = conn |> untracked() |> Conn.fetch_query_params()

    conn
    |> Conn.put_resp_header("content-security-policy", "frame-ancestors 'self'")
    |> Conn.put_resp_header("x-content-type-options", "nosniff")
    |> Conn.put_private(:phoenix_dev_toolbar_panel, Map.take(opts, [:path]))
    |> Phoenix.Controller.put_root_layout(html: {PhoenixDevToolbar.Layouts, :root})
    |> Phoenix.LiveView.Controller.live_render(PhoenixDevToolbar.PanelLive,
      session: %{"pdt_sid" => panel_sid(conn.query_params)}
    )
    |> Conn.halt()
  end

  defp serve_panel(conn, _opts), do: conn |> untracked() |> Conn.send_resp(405, "") |> Conn.halt()

  ## Export

  # Runs in the request process, untracked: EXPLAINs it runs are never recorded.
  defp serve_export(%Conn{method: "GET"} = conn) do
    conn = conn |> untracked() |> Conn.fetch_query_params()

    case EctoExport.request(conn.query_params) do
      {:ok, filename, body} ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> Conn.put_resp_header("cache-control", "no-store")
        |> Conn.put_resp_header("x-content-type-options", "nosniff")
        |> Conn.send_resp(200, body)
        |> Conn.halt()

      {:error, status} ->
        conn |> Conn.send_resp(status, "") |> Conn.halt()
    end
  end

  defp serve_export(conn), do: conn |> untracked() |> Conn.send_resp(405, "") |> Conn.halt()

  defp panel_sid(%{"sid" => sid}) when is_binary(sid), do: sid
  defp panel_sid(_params), do: ""

  # Already tracked: the plug is in the pipeline twice (endpoint and router).
  defp maybe_track(%Conn{private: %{phoenix_dev_toolbar: _}} = conn, _opts), do: conn

  defp maybe_track(conn, opts) do
    case page_request?(conn) do
      true -> track(conn, opts)
      false -> untracked(conn)
    end
  end

  # Connection processes serve many requests (keep-alive): a request we do not
  # track must not inherit the previous request's sid.
  defp untracked(conn) do
    Attribution.untrack()
    conn
  end

  defp track(conn, opts) do
    session = Store.new_session(Session.new(:request, path: conn.request_path))
    Attribution.track(session.sid)

    conn
    |> Conn.put_private(:phoenix_dev_toolbar, %{
      sid: session.sid,
      started_at: System.monotonic_time()
    })
    |> Conn.register_before_send(&before_send(&1, opts))
  rescue
    # Store tables missing while it restarts: serve the request untracked,
    # without the previous request's mark.
    ArgumentError -> untracked(conn)
  end

  defp page_request?(%Conn{method: "GET"} = conn) do
    top_level_document?(conn) and
      not Enum.any?(@skip_prefixes, &(strip_prefix(conn.path_info, &1) != :error))
  end

  defp page_request?(_conn), do: false

  # Browsers say what the response is for: only a top level document gets a
  # toolbar, not iframes nor fetch, htmx or Turbo partials (which also accept
  # text/html). Without the header, fall back to the Accept header.
  defp top_level_document?(conn) do
    case Conn.get_req_header(conn, "sec-fetch-dest") do
      [dest | _] ->
        dest == "document"

      [] ->
        conn |> Conn.get_req_header("accept") |> Enum.any?(&String.contains?(&1, "text/html"))
    end
  end

  ## Response

  @doc false
  # Runs inside the host's request process right before the response is sent:
  # any failure leaves the response untouched.
  @spec before_send(Conn.t(), map()) :: Conn.t()
  def before_send(%Conn{private: %{phoenix_dev_toolbar: %{sid: sid} = info}} = conn, opts) do
    {conn, injected?} = maybe_inject(conn, sid, opts)
    record(conn, info, injected?)
    # The response is done: keep the mark for `router_dispatch :stop`, but stop
    # resolving this connection process as a `$callers` parent.
    Attribution.forget_pid()
    conn
  rescue
    exception ->
      Logger.error(
        "[phoenix_dev_toolbar] response hook raised:\n" <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      conn
  end

  defp maybe_inject(%Conn{state: :set, status: 200, resp_body: body} = conn, sid, opts)
       when body != nil do
    with true <- html?(conn),
         true <- identity_encoding?(conn),
         body = IO.iodata_to_binary(body),
         [_ | _] = matches <- :binary.matches(body, "</body>") do
      {position, _length} = List.last(matches)
      tag = loader_tag(conn, sid, opts)

      injected =
        [
          binary_part(body, 0, position),
          tag,
          binary_part(body, position, byte_size(body) - position)
        ]

      # An ETag computed by an earlier hook no longer matches the body.
      {%{Conn.delete_resp_header(conn, "etag") | resp_body: injected}, true}
    else
      _ -> {conn, false}
    end
  end

  defp maybe_inject(conn, _sid, _opts), do: {conn, false}

  # Compressed bodies are left alone (they would not contain </body> anyway).
  defp identity_encoding?(conn) do
    case Conn.get_resp_header(conn, "content-encoding") do
      [] -> true
      ["identity"] -> true
      _ -> false
    end
  end

  defp html?(conn) do
    case Conn.get_resp_header(conn, "content-type") do
      ["text/html" <> _ | _] -> true
      _ -> false
    end
  end

  defp loader_tag(conn, sid, %{path: path, nonce_assign: nonce_assign}) do
    attrs = [
      {"src", path <> "/assets/loader.js"},
      {"data-pdt-sid", sid},
      {"data-pdt-path", path},
      {"data-pdt-reserve", reserve_attr(Config.reserve_space?())},
      {"nonce", nonce(conn, nonce_assign)}
    ]

    rendered =
      for {name, value} <- attrs, is_binary(value) do
        [" ", name, "=\"", Plug.HTML.html_escape(value), "\""]
      end

    ["<script defer", rendered, "></script>"]
  end

  # Only the opt out is written: the loader reserves space by default.
  defp reserve_attr(true), do: nil
  defp reserve_attr(false), do: "false"

  defp nonce(conn, key) do
    case conn.assigns do
      %{^key => nonce} when is_binary(nonce) -> nonce
      _ -> nil
    end
  end

  defp record(conn, %{sid: sid, started_at: started_at}, injected?) do
    data = %{
      method: conn.method,
      path: conn.request_path,
      status: conn.status,
      content_type: conn |> Conn.get_resp_header("content-type") |> List.first(),
      injected?: injected?
    }

    event = Event.new(:request, :response, data, duration: System.monotonic_time() - started_at)

    case Store.insert(sid, event) do
      :ok -> Notify.event(sid)
      _ -> :ok
    end
  end

  ## Assets

  defp serve_asset(conn, file) do
    conn = untracked(conn)

    with %{^file => {app, source, content_type}} <- @assets,
         path = Application.app_dir(app, ["priv", "static", source]),
         true <- File.regular?(path) do
      conn
      |> Conn.put_resp_content_type(content_type)
      |> Conn.put_resp_header("cache-control", "no-cache")
      |> Conn.put_resp_header("x-content-type-options", "nosniff")
      |> Conn.send_file(200, path)
      |> Conn.halt()
    else
      _ -> conn |> Conn.send_resp(404, "not found") |> Conn.halt()
    end
  end

  defp strip_prefix(path_info, []), do: {:ok, path_info}
  defp strip_prefix([segment | rest], [segment | prefix]), do: strip_prefix(rest, prefix)
  defp strip_prefix(_path_info, _prefix), do: :error
end
