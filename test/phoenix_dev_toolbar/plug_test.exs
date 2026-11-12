defmodule PhoenixDevToolbar.PlugTest do
  # Uses the node global Store; the test process plays the request process.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test
  import PhoenixDevToolbar.EnvHelpers
  import PhoenixDevToolbar.ProcessHelpers, only: [stop_store!: 0]

  alias PhoenixDevToolbar.Attribution
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Plug, as: ToolbarPlug
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @page "<html><body><p>hi</p></body></html>"
  @opts ToolbarPlug.init([])

  setup do
    Store.reset()

    on_exit(fn -> Store.reset() end)
  end

  defp page_conn(path \\ "/users") do
    :get |> conn(path) |> put_req_header("accept", "text/html,application/xhtml+xml")
  end

  defp respond(conn, opts \\ @opts, content_type \\ "text/html", status \\ 200, body \\ @page) do
    conn
    |> ToolbarPlug.call(opts)
    |> put_resp_content_type(content_type)
    |> send_resp(status, body)
  end

  defp sid(conn), do: conn.private.phoenix_dev_toolbar.sid

  defp loader_tags(conn), do: Regex.scan(~r/<script defer[^>]*><\/script>/, conn.resp_body)

  describe "HTML page requests" do
    test "are tracked as a request session and get the loader before </body>" do
      conn = respond(page_conn())
      sid = sid(conn)

      assert {:ok, %Session{kind: :request, path: "/users"}} = Store.session(sid)
      assert Attribution.tracked_sid() == sid

      assert conn.resp_body =~
               ~s(<p>hi</p><script defer src="/__pdt/assets/loader.js" data-pdt-sid="#{sid}" data-pdt-path="/__pdt"></script></body>)
    end

    test "tell the loader when reserving page space is turned off" do
      put_app_env(:reserve_space, false)

      assert [[tag]] = page_conn() |> respond() |> loader_tags()
      assert tag =~ ~s( data-pdt-reserve="false")
    end

    test "record the response with its duration" do
      conn = respond(page_conn())

      assert [%Event{plugin: :request, kind: :response, duration: duration, data: data}] =
               Store.events(sid(conn))

      assert is_integer(duration) and duration >= 0
      assert %{method: "GET", path: "/users", status: 200, injected?: true} = data
    end

    test "inject only once, before the last </body>" do
      body = "<html><body><pre>&lt;/body&gt; </body> in text</pre></body></html>"

      conn = respond(page_conn(), @opts, "text/html", 200, body)

      assert [_one] = loader_tags(conn)
      assert conn.resp_body =~ ~r{</pre><script defer[^>]*></script></body></html>$}
    end

    test "keep the mark after the response but stop being a $callers parent" do
      conn = respond(page_conn())

      assert Attribution.tracked_sid() == sid(conn)
      assert Store.sid_for_pid(self()) == nil
    end

    test "drop a stale ETag when the body changes" do
      conn = page_conn() |> ToolbarPlug.call(@opts) |> put_resp_header("etag", ~s("abc"))
      conn = conn |> put_resp_content_type("text/html") |> send_resp(200, @page)

      assert [_tag] = loader_tags(conn)
      assert get_resp_header(conn, "etag") == []
    end

    test "drop a preset content-length: it would truncate the injected body" do
      conn =
        page_conn()
        |> ToolbarPlug.call(@opts)
        |> put_resp_header("content-length", Integer.to_string(byte_size(@page)))
        |> put_resp_content_type("text/html")
        |> send_resp(200, @page)

      tag =
        ~s(<script defer src="/__pdt/assets/loader.js" data-pdt-sid="#{sid(conn)}" data-pdt-path="/__pdt"></script>)

      assert conn.resp_body == String.replace(@page, "</body>", tag <> "</body>")
      assert get_resp_header(conn, "content-length") == []
    end

    # The hook reads `resp_headers` with a comprehension: a stream that throws or
    # exits when enumerated fails the hook body without touching the Store.
    defp hostile_conn(kind) do
      stream = Stream.map([:header], fn _ -> hostile(kind) end)
      conn = page_conn() |> ToolbarPlug.call(@opts)
      %{conn | state: :set, status: 200, resp_body: @page, resp_headers: stream}
    end

    defp hostile(:throw), do: throw(:hostile)
    defp hostile(:exit), do: exit(:hostile)

    setup do
      key = {ToolbarPlug, :logged, :throw, :other}
      exit_key = {ToolbarPlug, :logged, :exit, :other}
      Enum.each([key, exit_key], &:persistent_term.erase/1)
      on_exit(fn -> Enum.each([key, exit_key], &:persistent_term.erase/1) end)
    end

    for kind <- [:throw, :exit] do
      test "a #{kind} in the response hook leaves the response untouched and the process untracked" do
        conn = hostile_conn(unquote(kind))
        assert Store.sid_for_pid(self()) == sid(conn)

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert ToolbarPlug.before_send(conn, @opts) == conn
          end)

        assert log =~ "response hook"
        assert Store.sid_for_pid(self()) == nil
      end
    end

    test "a failing response hook is logged once per failure class" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..3, do: ToolbarPlug.before_send(hostile_conn(:throw), @opts)
          ToolbarPlug.before_send(hostile_conn(:exit), @opts)
        end)

      assert [_, _] = Regex.scan(~r/response hook failed/, log)
    end

    test "inject once when the plug runs twice" do
      conn = page_conn() |> ToolbarPlug.call(@opts) |> respond()

      assert [_one] = loader_tags(conn)
      assert [_one_session] = Store.sessions()
    end

    test "count as pages only for top level documents, by sec-fetch-dest" do
      # page_conn/1 headers, only sec-fetch-dest differs between the cases.
      document = page_conn() |> put_req_header("sec-fetch-dest", "document") |> respond()

      assert [_tag] = loader_tags(document)

      # Not top level documents: no tag, no session.
      for dest <- ["iframe", "empty"] do
        conn = page_conn() |> put_req_header("sec-fetch-dest", dest) |> respond()

        assert loader_tags(conn) == []
        refute Map.has_key?(conn.private, :phoenix_dev_toolbar)
      end

      assert [_only_the_document] = Store.sessions()
    end

    test "use the configured path and the CSP nonce assign" do
      opts = ToolbarPlug.init(path: "/dev/toolbar/", nonce_assign: :nonce)

      conn = page_conn() |> assign(:nonce, ~s(abc"<)) |> respond(opts)

      assert conn.resp_body =~ ~s(src="/dev/toolbar/assets/loader.js")
      assert conn.resp_body =~ ~s(nonce="abc&quot;&lt;")
    end
  end

  describe "responses left untouched" do
    test "non HTML content types, non 200 statuses and bodies without </body>" do
      json = respond(page_conn(), @opts, "application/json", 200, ~s({"a":"</body>"}))
      error = respond(page_conn(), @opts, "text/html", 500, @page)
      fragment = respond(page_conn(), @opts, "text/html", 200, "<p>no body tag</p>")

      assert loader_tags(json) == []
      assert loader_tags(error) == []
      assert fragment.resp_body == "<p>no body tag</p>"

      assert [%Event{data: %{injected?: false, status: 500}}] = Store.events(sid(error))
    end

    test "compressed bodies" do
      conn =
        page_conn()
        |> ToolbarPlug.call(@opts)
        |> put_resp_header("content-encoding", "gzip")
        |> put_resp_content_type("text/html")
        |> send_resp(200, @page)

      assert conn.resp_body == @page
    end

    test "file responses" do
      conn =
        page_conn()
        |> ToolbarPlug.call(@opts)
        |> put_resp_content_type("text/html")
        |> send_file(200, Path.expand("../../README.md", __DIR__))

      assert [%Event{data: %{injected?: false}}] = Store.events(sid(conn))
    end

    test "chunked responses" do
      conn =
        page_conn()
        |> ToolbarPlug.call(@opts)
        |> put_resp_content_type("text/html")
        |> send_chunked(200)

      assert [%Event{data: %{injected?: false}}] = Store.events(sid(conn))
    end
  end

  describe "requests that are not tracked" do
    test "non HTML requests, iframes, partial fetches and live reload frames" do
      api = :get |> conn("/api/users") |> put_req_header("accept", "application/json")
      iframe = page_conn() |> put_req_header("sec-fetch-dest", "iframe")
      partial = page_conn() |> put_req_header("sec-fetch-dest", "empty")
      reload = page_conn("/phoenix/live_reload/frame")
      post = :post |> conn("/users") |> put_req_header("accept", "text/html")

      for conn <- [api, iframe, partial, reload, post] do
        conn = respond(conn)

        refute Map.has_key?(conn.private, :phoenix_dev_toolbar)
        assert loader_tags(conn) == []
      end

      assert Store.sessions() == []
    end

    test "clear the previous request's sid from a reused connection process" do
      first = respond(page_conn())
      assert Attribution.tracked_sid() == sid(first)

      :get |> conn("/api") |> put_req_header("accept", "application/json") |> respond()

      assert Attribution.tracked_sid() == nil
    end

    test "unknown paths under the toolbar's own pass through untracked" do
      conn = page_conn("/__pdt/elsewhere") |> ToolbarPlug.call(@opts)

      refute conn.halted
      refute Map.has_key?(conn.private, :phoenix_dev_toolbar)
      assert Store.sessions() == []
    end

    # GET is rendered by the panel LiveView, see PanelLiveTest.
    test "the panel answers only GET" do
      conn = :post |> conn("/__pdt/panel") |> ToolbarPlug.call(@opts)

      assert conn.halted
      assert conn.status == 405
    end

    test "every request, without crashing, while the Store is down" do
      first = respond(page_conn())
      assert Attribution.tracked_sid() == sid(first)

      stop_store!()

      page = respond(page_conn())
      api = :get |> conn("/api") |> put_req_header("accept", "application/json") |> respond()

      assert page.resp_body == @page
      assert api.status == 200
      assert Attribution.tracked_sid() == nil
    end

    test "everything, when the toolbar is disabled" do
      put_app_env(:enabled, false)

      conn = respond(page_conn())

      assert conn.resp_body == @page
      assert Store.sessions() == []
    end
  end

  describe "when the toolbar is disabled" do
    test "its own paths pass through, not halted and not answered" do
      put_app_env(:enabled, false)

      for path <- [
            "/__pdt/assets/loader.js",
            "/__pdt/panel?sid=x",
            "/__pdt/live/websocket?vsn=2.0.0",
            "/__pdt/export/ecto.json"
          ] do
        conn = :get |> conn(path) |> ToolbarPlug.call(@opts)

        refute conn.halted, path
        assert conn.state == :unset, path
      end

      assert Store.sessions() == []
    end
  end

  describe "CORS headers from the host" do
    # A host CORS plug runs before the toolbar's plug: the panel and the export
    # are same origin only.
    defp with_cors(conn) do
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-allow-credentials", "true")
      |> put_resp_header("vary", "origin")
    end

    @tag :capture_log
    test "are stripped from the panel, the export and a refusal" do
      for {path, host} <- [
            {"/__pdt/panel?sid=x", "www.example.com"},
            {"/__pdt/export/ecto.json?format=xml", "www.example.com"},
            {"/__pdt/panel?sid=x", "evil.example"}
          ] do
        # Through the endpoint: the panel renders a LiveView and needs one.
        conn =
          :get
          |> Phoenix.ConnTest.build_conn(path)
          |> Map.put(:host, host)
          |> with_cors()
          |> DemoWeb.Endpoint.call([])

        assert conn.halted
        assert get_resp_header(conn, "access-control-allow-origin") == [], path
        assert get_resp_header(conn, "access-control-allow-credentials") == [], path
        assert get_resp_header(conn, "vary") == ["origin"], path
      end
    end
  end

  describe "init/1" do
    test "warns once that :live_socket_path is gone" do
      :persistent_term.erase({ToolbarPlug, :live_socket_path})
      on_exit(fn -> :persistent_term.erase({ToolbarPlug, :live_socket_path}) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          ToolbarPlug.init(live_socket_path: "/live")
          ToolbarPlug.init(live_socket_path: "/live")
        end)

      assert [_one] = Regex.scan(~r/:live_socket_path option is gone/, log)
    end

    test "rejects paths that are not absolute and below the root" do
      for path <- ["/", "", "pdt"] do
        assert_raise ArgumentError, ~r/:path must be an absolute path/, fn ->
          ToolbarPlug.init(path: path)
        end
      end
    end
  end

  describe "assets" do
    test "are served from priv/static and halt the pipeline" do
      for {file, type, marker} <- [
            {"loader.js", "text/javascript", "data-pdt-sid"},
            {"panel.js", "text/javascript", "LiveSocket"},
            {"panel.css", "text/css", ".pdt-header"},
            # The host's own installed clients, not copies bundled by the toolbar.
            {"phoenix.js", "text/javascript", "var Phoenix"},
            {"live_view.js", "text/javascript", "var LiveView"}
          ] do
        conn = :get |> conn("/__pdt/assets/#{file}") |> ToolbarPlug.call(@opts)

        assert conn.halted
        assert conn.status == 200
        assert [^type <> _] = get_resp_header(conn, "content-type")
        assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
        assert conn.resp_body =~ marker
      end
    end

    defp asset(file, headers \\ []) do
      Enum.reduce(headers, conn(:get, "/__pdt/assets/#{file}"), fn {k, v}, c ->
        Plug.Conn.put_req_header(c, k, v)
      end)
      |> ToolbarPlug.call(@opts)
    end

    test "carry a stable weak ETag" do
      [etag] = get_resp_header(asset("panel.css"), "etag")

      assert etag =~ ~r/^W\/"\d+-\d+"$/
      assert get_resp_header(asset("panel.css"), "etag") == [etag]
    end

    test "answer 304 when If-None-Match matches" do
      [etag] = get_resp_header(asset("panel.css"), "etag")
      "W/" <> strong = etag

      for value <- [etag, "\"other\", " <> etag, strong, "*"] do
        conn = asset("panel.css", [{"if-none-match", value}])

        assert conn.halted
        assert conn.status == 304
        assert conn.resp_body == ""
        assert get_resp_header(conn, "etag") == [etag]
        assert get_resp_header(conn, "cache-control") == ["no-cache"]
        assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      end
    end

    test "answer 200 with the body on a stale If-None-Match" do
      conn = asset("panel.css", [{"if-none-match", ~s(W/"1-1")}])

      assert conn.status == 200
      assert conn.resp_body =~ ".pdt-header"
    end

    test "a 404 has no ETag" do
      conn = asset("secrets.exs")

      assert conn.status == 404
      assert get_resp_header(conn, "etag") == []
    end

    test "files outside the whitelist are a 404" do
      for file <- ["secrets.exs", "mix.exs"] do
        conn = :get |> conn("/__pdt/assets/#{file}") |> ToolbarPlug.call(@opts)

        assert conn.halted
        assert conn.status == 404
      end
    end
  end

  describe "Ecto export" do
    defp export(query, method \\ :get) do
      method
      |> conn("/__pdt/export/ecto.json?" <> URI.encode_query(query))
      |> ToolbarPlug.call(@opts)
    end

    defp page_sid, do: Store.new_session(Session.new(:request, path: "/users")).sid

    test "answers a known page's export as an attachment, untracked" do
      sid = page_sid()
      conn = export(%{"format" => "short", "root" => sid, "sids" => sid})

      assert conn.halted
      assert conn.status == 200
      assert ["attachment; filename=" <> _name] = get_resp_header(conn, "content-disposition")
      assert ["application/json" <> _charset] = get_resp_header(conn, "content-type")

      assert %{"format" => "short", "path" => "/users", "count" => 0} =
               Jason.decode!(conn.resp_body)

      refute Map.has_key?(conn.private, :phoenix_dev_toolbar)
    end

    # The host's JSON library encodes the file (ADR 08): here the built-in one.
    @tag :json_module
    test "is encoded with the built-in JSON module when the host uses it" do
      put_env(:phoenix, :json_library, JSON)
      sid = page_sid()
      conn = export(%{"format" => "short", "root" => sid, "sids" => sid})

      assert conn.status == 200

      assert %{"format" => "short", "path" => "/users", "count" => 0} =
               JSON.decode!(conn.resp_body)
    end

    test "refuses bad params, unknown pages and other methods" do
      sid = page_sid()
      many = Enum.join(for(_i <- 1..5, do: page_sid()), ",")

      assert export(%{"format" => "xml", "root" => sid, "sids" => sid}).status == 400
      assert export(%{"format" => "short", "root" => sid}).status == 400
      assert export(%{"format" => "short", "root" => sid, "sids" => many}).status == 400
      assert export(%{"format" => "short", "root" => "nope", "sids" => "nope"}).status == 404
      assert export(%{"format" => "short", "root" => "nope", "sids" => sid}).status == 400
      assert export(%{"format" => "short", "root" => sid, "sids" => sid}, :post).status == 405
    end
  end
end
