defmodule PhoenixDevToolbar.LabelTest do
  # Uses the node global Store, persistent_term and the DemoWeb endpoint.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.EnvHelpers
  import PhoenixDevToolbar.JsonHelpers, only: [builtin_json_decode!: 1]
  import PhoenixDevToolbar.PageHelpers

  alias PhoenixDevToolbar.Label
  alias PhoenixDevToolbar.Mcp.Tools
  alias PhoenixDevToolbar.Report
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store

  @flag {PhoenixDevToolbar.Label, :function_failed}

  setup do
    Store.reset()
    :persistent_term.erase(@flag)

    on_exit(fn ->
      Store.reset()
      :persistent_term.erase(@flag)
    end)
  end

  def by_path(conn), do: "mfa:" <> conn.request_path
  def by_assign(conn), do: conn.assigns[:persona]
  def boom(_conn), do: raise("boom")
  def throws(_conn), do: throw(:nope)
  def exits(_conn), do: exit(:gone)
  def not_text(_conn), do: %{id: 42}

  defp label_of(sid) do
    assert %{label: label} = Report.sessions() |> Enum.find(&(&1.sid == sid))
    label
  end

  defp load(path, headers \\ []) do
    conn =
      Enum.reduce(headers, build_conn(), fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)

    load_page(conn, path)
  end

  describe "the label: function" do
    test "a 1-arity function labels the page" do
      put_app_env(:label, fn conn -> "fn-" <> to_string(conn.request_path) end)

      {_conn, sid} = load("/demo")
      assert label_of(sid) == "fn-/demo"
    end

    test "an MFA is called with the conn" do
      put_app_env(:label, {__MODULE__, :by_path})

      {_conn, sid} = load("/demo")
      assert label_of(sid) == "mfa:/demo"
    end

    test "a function that finds no user yields no label" do
      put_app_env(:label, {__MODULE__, :by_assign})

      {_conn, sid} = load("/demo")
      assert label_of(sid) == nil
    end

    for {name, fun} <- [raising: :boom, throwing: :throws, exiting: :exits, non_text: :not_text] do
      test "a #{name} function yields no label and the page still renders" do
        put_app_env(:label, {__MODULE__, unquote(fun)})

        log =
          capture_log(fn ->
            assert {_conn, sid} = load("/demo")
            assert label_of(sid) == nil
          end)

        case unquote(fun) do
          :not_text -> refute log =~ "the label function failed"
          _failing -> assert log =~ "the label function failed"
        end
      end
    end

    test "a failing function logs once per boot" do
      put_app_env(:label, {__MODULE__, :boom})

      log =
        capture_log(fn ->
          load("/demo")
          load("/demo")
        end)

      assert length(String.split(log, "the label function failed")) == 2
    end

    test "an invalid value is a boot warning and no label" do
      put_app_env(:label, "alice")
      log = capture_log(&PhoenixDevToolbar.Config.warn_ui/0)
      assert log =~ "invalid label"

      {_conn, sid} = load("/demo")
      assert label_of(sid) == nil

      put_app_env(:label, fn _ -> "ok" end)
      refute capture_log(&PhoenixDevToolbar.Config.warn_ui/0) =~ "invalid label"
    end
  end

  describe "?pdt_label=" do
    test "labels the request and sets a session cookie" do
      {conn, sid} = load("/demo?pdt_label=alice")

      assert label_of(sid) == "alice"
      cookie = conn.resp_cookies["_pdt_label"]
      assert cookie.http_only and cookie.same_site == "Lax" and cookie.path == "/"
      refute cookie[:max_age]
    end

    test "the cookie labels a later request" do
      {conn, _sid} = load("/demo?pdt_label=alice")
      value = conn.resp_cookies["_pdt_label"].value

      {_conn, sid} = load("/demo", [{"cookie", "a=b; _pdt_label=#{value}"}])
      assert label_of(sid) == "alice"
    end

    test "an empty param deletes the cookie and falls through to the function" do
      put_app_env(:label, fn _conn -> "from-fn" end)

      {conn, sid} =
        load("/demo?pdt_label=", [
          {"cookie", "_pdt_label=#{Base.url_encode64("alice", padding: false)}"}
        ])

      assert label_of(sid) == "from-fn"
      assert conn.resp_cookies["_pdt_label"].max_age == 0
    end

    test "precedence: param, then cookie, then the function" do
      put_app_env(:label, fn _conn -> "from-fn" end)
      cookie = {"cookie", "_pdt_label=#{Base.url_encode64("from-cookie", padding: false)}"}

      {_conn, a} = load("/demo?pdt_label=from-param", [cookie])
      {_conn, b} = load("/demo", [cookie])
      {_conn, c} = load("/demo")

      assert {label_of(a), label_of(b), label_of(c)} == {"from-param", "from-cookie", "from-fn"}
    end

    test "a garbled cookie is ignored" do
      {_conn, sid} = load("/demo", [{"cookie", "_pdt_label=!!!"}])
      assert label_of(sid) == nil
    end
  end

  describe "sanitizing" do
    test "a 200 byte multi-byte label is cut to at most 64 bytes on a boundary" do
      label = String.duplicate("é", 100)
      put_app_env(:label, fn _conn -> label end)

      {_conn, sid} = load("/demo")
      cut = label_of(sid)
      assert byte_size(cut) <= 64 and String.valid?(cut) and byte_size(cut) > 60
    end

    test "control characters are stripped and the text trimmed" do
      assert PhoenixDevToolbar.Label.sanitize("  al\u0000i\nce\e[0m \t") == "alice[0m"
      assert PhoenixDevToolbar.Label.sanitize("\n \t") == nil
      assert PhoenixDevToolbar.Label.sanitize(<<0xFF, "ok">>) == "ok"
      assert PhoenixDevToolbar.Label.sanitize(nil) == nil
    end
  end

  describe "sanitizing more" do
    test "integers and atoms become text, booleans and nil give none" do
      assert Label.sanitize(42) == "42"
      assert Label.sanitize(:alice) == "alice"
      assert Label.sanitize(true) == nil
      assert Label.sanitize(false) == nil
      assert Label.sanitize(nil) == nil
    end

    test "format characters (bidi override, zero width) are stripped" do
      assert Label.sanitize("al\u202Eic\u200Be\uFEFF") == "alice"
    end

    test "a huge label is cut before the regex runs" do
      assert Label.sanitize(String.duplicate("a", 1_000_000)) == String.duplicate("a", 64)
    end

    test "an integer id from the label function labels the page" do
      put_app_env(:label, fn _conn -> 7 end)
      {_conn, sid} = load("/demo")
      assert label_of(sid) == "7"
    end
  end

  describe "inherit" do
    defp chain(count, root_label) do
      for i <- 0..(count - 1) do
        %Session{
          sid: "s#{i}",
          kind: :live_view,
          started_at: i,
          parent: if(i == 0, do: nil, else: "s#{i - 1}"),
          label: if(i == 0, do: root_label)
        }
      end
    end

    test "walks at most 10 hops" do
      assert %{label: "x"} = chain(11, "x") |> Label.inherit() |> Enum.at(10)
      assert %{label: nil} = chain(12, "x") |> Label.inherit() |> Enum.at(11)
    end

    test "a parent cycle ends with no label" do
      a = %Session{sid: "a", kind: :live_view, started_at: 1, parent: "b"}
      b = %Session{sid: "b", kind: :live_view, started_at: 2, parent: "a"}
      assert [%{label: nil}, %{label: nil}] = Label.inherit([a, b])
    end
  end

  describe "label survives and cookies" do
    test "a connected mount keeps the label once its request is swept" do
      {_host, _sid} = visit("/demo?pdt_label=alice")
      [request] = Report.sessions(kind: :request)
      Store.sweep(System.system_time(:microsecond) + :timer.hours(1) * 1000)
      assert Store.session(request.sid) == :error

      assert [%{label: "alice", sid: mount_sid}] = Report.sessions(kind: :live_view)
      assert [%{sid: ^mount_sid}] = Report.sessions(label: "alice")
      assert Report.summary(mount_sid).session.label == "alice"
    end

    test "the host's own cookie and _pdt_label are both sent, Secure only over https" do
      sent = fn scheme, query ->
        :get
        |> Plug.Test.conn("/page" <> query)
        |> Map.put(:scheme, scheme)
        |> browser_headers()
        |> PhoenixDevToolbar.Plug.call(PhoenixDevToolbar.Plug.init([]))
        |> Plug.Conn.put_resp_cookie("host_cookie", "1")
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, "<html><body>hi</body></html>")
      end

      http = sent.(:http, "?pdt_label=alice")

      assert %{"host_cookie" => _, "_pdt_label" => %{http_only: true, same_site: "Lax"} = c} =
               http.resp_cookies

      refute c[:secure]
      assert %{"_pdt_label" => %{secure: true}} = sent.(:https, "?pdt_label=bob").resp_cookies
    end
  end

  describe "reading" do
    test "a connected mount inherits the label, and list_pages shows and filters it" do
      {host, sid} = visit("/demo?pdt_label=alice")
      {_other, other_sid} = load("/demo?pdt_label=bob")

      assert [%{"label" => "alice", "live_views" => [%{"label" => "alice"}]}] =
               list_pages(%{"label" => "alice"})

      assert [%{"sid" => ^other_sid, "label" => "bob"}] = list_pages(%{"label" => "bob"})
      assert [] = list_pages(%{"label" => "carol"})
      assert [%{"sid" => ^other_sid}, %{"sid" => ^sid}] = list_pages(%{})

      mount = Report.sessions(kind: :live_view) |> List.first()
      assert mount.label == "alice"
      assert Report.sessions(label: "alice") |> length() == 2
      assert Report.summary(sid).session.label == "alice"
      assert Report.markdown(sid) =~ "[alice]"
      _ = host
    end

    test "the Request tab shows the label only when there is one" do
      {_conn, labeled} = load("/demo?pdt_label=alice")
      {_conn, plain} = load("/demo")

      panel = open_tab(labeled, "request")
      assert has_element?(panel, ~s(#pdt-requests [data-pdt-label="alice"]), "alice")

      panel = open_tab(plain, "request")
      refute has_element?(panel, "#pdt-requests [data-pdt-label]")
    end
  end

  defp list_pages(args) do
    assert {:ok, %{"pages" => pages}} =
             Tools.call("list_pages", args, base_url: "http://localhost:4000/__pdt")

    pages |> PhoenixDevToolbar.Mcp.Json.encode!() |> builtin_json_decode!()
  end
end
