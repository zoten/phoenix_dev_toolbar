defmodule PhoenixDevToolbar.Plug do
  @moduledoc """
  The whole toolbar integration: tracks page requests, injects the toolbar
  into HTML responses, and serves the toolbar's own assets and panel.

  Add it to your endpoint, next to `Phoenix.LiveReloader`:

      if code_reloading? do
        plug PhoenixDevToolbar.Plug
      end

  No router changes are needed: the panel is a LiveView rendered by this plug
  under `:path`, and it connects through its own socket at `<path>/live`, not
  through the host's `LiveSocket` or its `app.js`. This keeps the package
  installable with `only: :dev`, since nothing outside the `code_reloading?`
  block references it.

  ## Options

    * `:path` - where the toolbar lives, an absolute path below the root.
      Defaults to `"/__pdt"`. The panel, its assets, its socket and the export
      are served under it.
    * `:nonce_assign` - the `conn.assigns` key holding a CSP nonce for the
      injected script tag. Defaults to `:csp_nonce`. A nonce based
      `script-src` needs the same nonce in the assign:

          # in a plug before this one, or in your CSP plug
          conn = Plug.Conn.assign(conn, :csp_nonce, nonce)

          # or, if your plug stores it elsewhere
          plug PhoenixDevToolbar.Plug, nonce_assign: :my_nonce

  ## Standalone panel

  The panel also opens in a browser tab of its own, for example from a
  browser-driving agent:

    * `<path>/panel?path=/posts` - the newest page whose path is exactly `/posts`
    * `<path>/panel` - the newest page
    * `<path>/panel?sid=<sid>` - one page, by the sid `PhoenixDevToolbar.Report`
      returns, or the `data-pdt-sid` of the toolbar's script tag on the page

  A page is the request and the LiveView it mounted, as the toolbar shows it.
  The page is picked when the panel loads: reload the panel for a newer one.
  `?path=` matches the path the page started at (a live patch keeps its
  LiveView's mount path).

  `?path=` and the newest page find a page without its sid, so they follow the
  MCP client rule below: this machine unless `mcp: [clients: ...]` says
  otherwise. Other clients get an empty panel that says why; `?sid=` works for
  any client the access rules let in.

  Rows carry stable `data-pdt-*` attributes with raw values. Booleans are
  present only when true; missing values are left out.

  | Element | Attributes |
  |---|---|
  | `#pdt-panel` | `data-pdt-root` (root sid), `data-pdt-sids` (comma separated) |
  | tab section | `data-pdt-tab` (plugin id); hidden tabs are in the DOM too |
  | every event row | `data-pdt-row`, `data-pdt-sid`, `data-pdt-seq`, `data-pdt-duration-us` |
  | `query` row | `data-pdt-source`, `data-pdt-error`, `data-pdt-n-plus-one` |
  | `n-plus-one` row | `data-pdt-count`, `data-pdt-callbacks` |
  | `callback` row | `data-pdt-callback`, `data-pdt-event`, `data-pdt-error` |
  | `render` row | `data-pdt-error` |
  | `client` row | `data-pdt-event` (the `phx:*` type) |
  | `request` row | `data-pdt-kind`, `data-pdt-method`, `data-pdt-status`, `data-pdt-error` |
  | `profile` row | `data-pdt-callback`, `data-pdt-count`, `data-pdt-total-us`, `data-pdt-max-us` |
  | `#pdt-empty` | `data-pdt-lookup`: `sid`, `path`, `newest` or `gated` |
  | phase tag in a row | `data-pdt-phase`: `http`, `live` or `client` |
  | `callback` row parts | `data-pdt-changed`, `data-pdt-changed-more`, `data-pdt-pushed`, `data-pdt-pushed-unavailable`; `data-pdt-field` on client fields, `data-pdt-origin` on `n-plus-one` rows |
  | crash rows (`callback`, `render`), snapshot entry | `data-pdt-stack-args`, `data-pdt-snapshot-changed` |
  | tab button, summary badge | `data-pdt-error`, `data-pdt-level` |
  | Eval run output | `data-pdt-eval`: `output`, `result` or `error` |

  The decision is [ADR 14](https://github.com/zoten/phoenix_dev_toolbar/blob/main/adr/14-standalone-panel-and-row-attributes.md).

  ## MCP server

  `<path>/mcp` is an MCP server (Streamable HTTP, MCP 2025-03-26 to 2026-07-28)
  with read-only tools over `PhoenixDevToolbar.Report`: `list_pages`,
  `page_summary`, `page_queries`, `page_callbacks`, `page_n_plus_one` and
  `page_errors`. By default it answers only clients on this machine (a loopback
  peer or one of the machine's own addresses, no proxy headers), with an allowed
  `Host` and no foreign `Origin`. It is on with the toolbar:

      config :phoenix_dev_toolbar, mcp: false                              # off
      config :phoenix_dev_toolbar, mcp: [clients: ["192.168.1.0/24"]]     # also these
      config :phoenix_dev_toolbar, mcp: [clients: :any]                   # anyone

  Anything on this machine that relays to the dev server (an SSH forward, socat,
  a local proxy without `X-Forwarded-*` headers, a VM or container with
  user-mode NAT) counts as this machine. Client setup is in the README, the
  protocol details in
  [ADR 15](https://github.com/zoten/phoenix_dev_toolbar/blob/main/adr/15-mcp-endpoint.md).

  ## Access rules

  The panel, its socket, the export and the MCP endpoint answer only a request whose `Host` cannot
  be rebound: an IP address, `localhost`, your endpoint's `url: [host: ...]` or a
  name listed in `config :phoenix_dev_toolbar, allowed_hosts: [...]`. The socket
  also refuses a missing `Origin`, or one that differs from the host the request
  was sent to, unless it is listed in `allowed_origins: [...]` (for a proxy or
  tunnel that rewrites the `Host` header). The MCP endpoint and the standalone
  panel's sid-less lookups add the client rule of the "MCP server" section;
  process actions (`actions:`) and the Eval plugin's code use the same
  "this machine" rule (`:local`). The README's "Docker or LAN access" section
  sums it all up.

  The plug does nothing when the toolbar is disabled
  (`config :phoenix_dev_toolbar, enabled: false`).
  """

  @behaviour Plug

  require Logger

  alias PhoenixDevToolbar.Attribution
  alias PhoenixDevToolbar.ClientMatch
  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Config
  alias PhoenixDevToolbar.EctoExport
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.HostCheck
  alias PhoenixDevToolbar.Label
  alias PhoenixDevToolbar.Mcp
  alias PhoenixDevToolbar.McpHint
  alias PhoenixDevToolbar.Notify
  alias PhoenixDevToolbar.OriginCheck
  alias PhoenixDevToolbar.PageLookup
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

      # The MCP endpoint (ADR 15): its own guards, plain text refusals.
      {:ok, ["mcp"]} ->
        conn
        |> Conn.register_before_send(&strip_cors/1)
        |> untracked()
        |> Mcp.Endpoint.call(opts.path)

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
    conn = Conn.register_before_send(conn, &strip_cors/1)

    case HostCheck.allowed?(conn) do
      true ->
        serve.(conn)

      false ->
        HostCheck.log_refused(conn.host)
        conn |> untracked() |> refuse(opts) |> Conn.halt()
    end
  end

  # The panel and the export are same origin only: a host CORS plug running
  # before this one must not open them to another origin.
  defp strip_cors(conn) do
    %{conn | resp_headers: Enum.reject(conn.resp_headers, &cors_header?/1)}
  end

  defp cors_header?({"access-control-" <> _rest, _value}), do: true
  defp cors_header?(_header), do: false

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
      session: Map.put(panel_session(conn), "pdt_base", Mcp.Endpoint.base_url(conn, opts.path))
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

  # `?sid=` is the loader's iframe. Without it the panel is opened on its own
  # (ADR 14): `?path=` picks the newest page at that exact path, nothing at all
  # the newest page, both only for a client the MCP rule accepts (`:off` counts
  # as `:local`). ETS reads only, resolved once per panel load. The session says
  # how the page was asked for, so the empty state can say why there is none.
  # `own_addresses` is injectable for tests; the plug passes the default.
  @doc false
  @spec panel_session(Conn.t(), (-> [:inet.ip_address()])) :: %{String.t() => String.t()}
  def panel_session(
        %Conn{query_params: params} = conn,
        own_addresses \\ &ClientMatch.own_addresses/0
      ) do
    case params do
      %{"sid" => sid} when is_binary(sid) ->
        %{"pdt_sid" => sid}

      _no_sid ->
        case standalone_allowed?(conn, own_addresses) do
          true -> standalone_session(params)
          false -> %{"pdt_sid" => "", "pdt_lookup" => gated_lookup(Config.mcp())}
        end
    end
  end

  # `gated_off`: MCP is off, so the hint must not suggest `mcp: [clients: ...]` as is.
  defp gated_lookup(:off), do: "gated_off"
  defp gated_lookup(_mode), do: "gated"

  defp standalone_allowed?(conn, own_addresses) do
    mode =
      case Config.mcp() do
        :off -> :local
        mode -> mode
      end

    ClientMatch.allowed?(conn.remote_ip, mode, OriginCheck.proxied?(conn), own_addresses)
  end

  defp standalone_session(%{"path" => path}) when is_binary(path) do
    %{
      "pdt_sid" => PageLookup.newest(path: path) || "",
      "pdt_lookup" => "path",
      "pdt_path" => String.slice(path, 0, 200)
    }
  end

  defp standalone_session(%{"path" => _not_a_string}),
    do: %{"pdt_sid" => "", "pdt_lookup" => "path", "pdt_path" => "(not a string)"}

  defp standalone_session(_params),
    do: %{"pdt_sid" => PageLookup.newest() || "", "pdt_lookup" => "newest"}

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
    McpHint.announce(conn, opts.path)

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
    # `Label.resolve/1` never raises: its conn (with the label cookie) is the
    # one every later failure path returns.
    {conn, label} = Label.resolve(conn)
    finish(conn, sid, info, label, opts)
  after
    # The response is done, whatever happened: keep the mark for
    # `router_dispatch :stop`, but stop resolving this connection process as a
    # `$callers` parent. `forget_pid/0` rescues the only error it can raise.
    Attribution.forget_pid()
  end

  defp finish(conn, sid, info, label, opts) do
    Label.store(sid, label)
    {injected, injected?} = maybe_inject(conn, sid, opts)
    record(injected, info, injected?, label)
    injected
  catch
    # Every class: a throw or exit must not escape into the host's send_resp.
    kind, reason ->
      Collector.log_failure(
        PhoenixDevToolbar.Plug,
        "response hook failed",
        kind,
        reason,
        __STACKTRACE__
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

      # An ETag or content-length set by an earlier hook no longer matches the
      # body; the server adapter computes the length for `send_resp`.
      conn = conn |> Conn.delete_resp_header("etag") |> Conn.delete_resp_header("content-length")
      {%{conn | resp_body: injected}, true}
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

  # The default budget is the loader's own: no attribute.
  defp inspect_nodes_attr(500), do: nil
  defp inspect_nodes_attr(nodes), do: Integer.to_string(nodes)

  defp loader_tag(conn, sid, %{path: path, nonce_assign: nonce_assign}) do
    attrs = [
      {"src", path <> "/assets/loader.js"},
      {"data-pdt-sid", sid},
      {"data-pdt-path", path},
      {"data-pdt-reserve", reserve_attr(Config.reserve_space?())},
      {"data-pdt-pill", pill_attr(Config.pill_corner())},
      {"data-pdt-shortcut", Config.shortcut()},
      {"data-pdt-inspect-nodes", inspect_nodes_attr(Config.inspect_nodes())},
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

  # Only a non default corner is written, as `bottom-left` and so on.
  defp pill_attr(:bottom_right), do: nil
  defp pill_attr(corner), do: corner |> Atom.to_string() |> String.replace("_", "-")

  defp nonce(conn, key) do
    case conn.assigns do
      %{^key => nonce} when is_binary(nonce) -> nonce
      _ -> nil
    end
  end

  defp record(conn, %{sid: sid, started_at: started_at}, injected?, label) do
    data = %{
      method: conn.method,
      path: conn.request_path,
      status: conn.status,
      content_type: conn |> Conn.get_resp_header("content-type") |> List.first(),
      injected?: injected?,
      label: label
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
         {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} <-
           File.stat(path, time: :posix) do
      etag = ~s(W/"#{size}-#{mtime}")

      conn =
        conn
        |> Conn.put_resp_content_type(content_type)
        |> Conn.put_resp_header("cache-control", "no-cache")
        |> Conn.put_resp_header("x-content-type-options", "nosniff")
        |> Conn.put_resp_header("etag", etag)

      conn
      |> send_asset(etag_match?(conn, etag), path)
      |> Conn.halt()
    else
      _ -> conn |> Conn.send_resp(404, "not found") |> Conn.halt()
    end
  end

  defp send_asset(conn, true, _path), do: Conn.send_resp(conn, 304, "")
  defp send_asset(conn, false, path), do: Conn.send_file(conn, 200, path)

  # RFC 9110 weak comparison: list of tags, `W/` prefix ignored, `*` matches.
  defp etag_match?(conn, etag) do
    conn
    |> Conn.get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&strip_weak(String.trim(&1)))
    |> Enum.any?(&(&1 == "*" or &1 == strip_weak(etag)))
  end

  defp strip_weak("W/" <> tag), do: tag
  defp strip_weak(tag), do: tag

  defp strip_prefix(path_info, []), do: {:ok, path_info}
  defp strip_prefix([segment | rest], [segment | prefix]), do: strip_prefix(rest, prefix)
  defp strip_prefix(_path_info, _prefix), do: :error
end
