defmodule PhoenixDevToolbar.PlugTest do
  # Uses the node global Store; the test process plays the request process.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias PhoenixDevToolbar.Attribution
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Plug, as: ToolbarPlug
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @page "<html><body><p>hi</p></body></html>"
  @opts ToolbarPlug.init([])

  setup do
    Store.reset()

    on_exit(fn ->
      Application.delete_env(:phoenix_dev_toolbar, :enabled)
      Store.reset()
    end)
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

    test "record the response with its duration" do
      conn = respond(page_conn())

      assert [%Event{plugin: :request, kind: :response, duration: duration, data: data}] =
               Store.events(sid(conn))

      assert is_integer(duration)
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

    test "inject once when the plug runs twice" do
      conn = page_conn() |> ToolbarPlug.call(@opts) |> respond()

      assert [_one] = loader_tags(conn)
      assert [_one_session] = Store.sessions()
    end

    test "count as pages only for top level documents, by sec-fetch-dest" do
      document = page_conn() |> put_req_header("sec-fetch-dest", "document") |> respond()

      assert [_tag] = loader_tags(document)
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
      respond(page_conn())
      assert Attribution.tracked_sid()

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
      respond(page_conn())
      assert Attribution.tracked_sid()

      :ok = Supervisor.terminate_child(PhoenixDevToolbar.Supervisor, Store)
      on_exit(fn -> Supervisor.restart_child(PhoenixDevToolbar.Supervisor, Store) end)

      page = respond(page_conn())
      api = :get |> conn("/api") |> put_req_header("accept", "application/json") |> respond()

      assert page.resp_body == @page
      assert api.status == 200
      assert Attribution.tracked_sid() == nil
    end

    test "everything, when the toolbar is disabled" do
      Application.put_env(:phoenix_dev_toolbar, :enabled, false)

      conn = respond(page_conn())

      assert conn.resp_body == @page
      assert Store.sessions() == []
    end
  end

  describe "init/1" do
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
            {"panel.css", "text/css", ".pdt-header"}
          ] do
        conn = :get |> conn("/__pdt/assets/#{file}") |> ToolbarPlug.call(@opts)

        assert conn.halted
        assert conn.status == 200
        assert [^type <> _] = get_resp_header(conn, "content-type")
        assert conn.resp_body =~ marker
      end
    end

    test "files outside the whitelist are a 404" do
      for file <- ["secrets.exs", "mix.exs"] do
        conn = :get |> conn("/__pdt/assets/#{file}") |> ToolbarPlug.call(@opts)

        assert conn.halted
        assert conn.status == 404
      end
    end
  end
end
