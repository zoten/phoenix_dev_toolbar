defmodule PhoenixDevToolbar.EctoExportPanelTest do
  # The Ecto tab's export end to end (ADR 08): a real host LiveView runs real
  # SQLite queries. Download is a same-origin link the plug answers; Copy
  # pushes the JSON payload to the tab's hook.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers

  @endpoint DemoWeb.Endpoint

  defp run(host, panel, sql, params) do
    render_hook(host, "sqlite", %{"sql" => sql, "params" => params})
    _ = flush(panel)
  end

  defp choose(panel, fields), do: panel |> form("#pdt-ecto-export", fields) |> render_change()

  defp copy(panel, fields) do
    panel
    |> form("#pdt-ecto-export", fields)
    |> put_submitter("#pdt-export-copy")
    |> render_submit()

    render_async(panel)
  end

  # Follows the Download link as the browser would: relative to the panel's URL.
  defp download(panel) do
    [href] =
      panel
      |> element("#pdt-export-download")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("href")

    get(build_conn(), "/__pdt/" <> href)
  end

  defp phases(%{"queries" => queries}), do: Enum.frequencies_by(queries, & &1["phase"])

  defp form_page(panel) do
    panel
    |> element("#pdt-ecto-export")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-pdt-page")
  end

  describe "a panel opened before its LiveView connects" do
    setup :sqlite_plugins

    # /demo/loaders loads in Task.async children, in the dead render and again
    # in the connected mount. Copied before the LiveView joins, an export holds
    # the request only: it says which page it was built from, so the hook drops
    # it once the form shows a newer page.
    test "an export says its page; once the LiveView joins, both export it" do
      {conn, root} = load_page("/demo/loaders")
      panel = open_panel(root)

      copy(panel, %{"format" => "full"})
      assert_push_event(panel, "pdt:export", %{payload: early, page: ^root})
      assert %{"path" => "/demo/loaders"} = early
      assert phases(early) == %{"http" => 2}

      {:ok, _host, _html} = live(conn)
      _ = render(panel)
      assert [page] = form_page(panel)
      assert [^root, _live] = String.split(page, ",")

      copy(panel, %{"format" => "full"})
      assert_push_event(panel, "pdt:export", %{payload: copied, page: ^page})
      assert %{"path" => "/demo/loaders"} = copied
      assert phases(copied) == %{"http" => 2, "live" => 2}

      choose(panel, %{"format" => "full"})
      downloaded = Jason.decode!(download(panel).resp_body)
      assert %{"path" => "/demo/loaders"} = downloaded
      assert phases(downloaded) == %{"http" => 2, "live" => 2}
    end
  end

  describe "on a connected page" do
    setup :sqlite_panel

    test "no queries, no export form", %{panel: panel} do
      refute has_element?(panel, "#pdt-ecto-export")
    end

    test "Download is a same-origin file of the page's queries", %{host: host, panel: panel} do
      run(host, panel, "SELECT * FROM users WHERE id = ?", [1])

      assert has_element?(panel, "#pdt-export-download[download]")
      conn = download(panel)

      assert conn.status == 200
      assert [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert disposition =~ ~r/^attachment; filename="ecto-queries-short-\d{8}T\d{6}\.json"$/
      assert %{"format" => "short", "queries" => queries} = Jason.decode!(conn.resp_body)

      assert [%{"sql" => "SELECT * FROM users WHERE id = ?", "params" => "[1]"} = row] =
               Enum.filter(queries, &(&1["sql"] =~ "users WHERE"))

      assert Map.keys(row) |> Enum.sort() == ~w(location params seq sql)
    end

    test "Download follows the chosen format and EXPLAIN", %{host: host, panel: panel} do
      run(host, panel, "SELECT * FROM users WHERE id = ?", [1])
      choose(panel, %{"format" => "full", "explain" => "true"})

      %{"format" => "full", "queries" => queries} = Jason.decode!(download(panel).resp_body)
      select = Enum.find(queries, &(&1["sql"] == "SELECT * FROM users WHERE id = ?"))

      assert %{"status" => "ok", "plan" => plan} = select["explain"]
      assert plan =~ "SEARCH users USING INTEGER PRIMARY KEY"
      assert %{"phase" => "live", "repo" => "DemoWeb.SQLiteRepo"} = select
    end

    test "Copy pushes the full export with EXPLAIN plans", %{host: host, panel: panel} do
      run(host, panel, "SELECT * FROM users WHERE id = ?", [1])
      run(host, panel, "UPDATE users SET name = name WHERE id = ?", [1])

      copy(panel, %{"format" => "full", "explain" => "true"})

      assert_push_event(panel, "pdt:export", %{payload: %{"queries" => queries}})

      select = Enum.find(queries, &(&1["sql"] == "SELECT * FROM users WHERE id = ?"))
      update = Enum.find(queries, &(&1["sql"] =~ "UPDATE users"))

      assert %{"status" => "ok", "plan" => plan} = select["explain"]
      assert plan =~ "SEARCH users USING INTEGER PRIMARY KEY"
      assert %{"status" => "not_explainable"} = update["explain"]
    end

    test "Copy without EXPLAIN runs none", %{host: host, panel: panel} do
      run(host, panel, "SELECT id FROM users", [])

      copy(panel, %{"format" => "full"})

      assert_push_event(panel, "pdt:export", %{payload: %{"queries" => [_ | _] = queries}})
      assert Enum.all?(queries, &(&1["explain"] == %{"status" => "not_requested"}))
    end

    test "the chosen format and EXPLAIN survive an export", %{host: host, panel: panel} do
      run(host, panel, "SELECT id FROM users", [])
      choice = %{"format" => "full", "explain" => "true"}

      choose(panel, choice)
      copy(panel, choice)
      assert_push_event(panel, "pdt:export", %{})

      assert has_element?(panel, "#pdt-export-full[checked]")
      assert has_element?(panel, "#pdt-export-explain[checked]")
      refute has_element?(panel, "#pdt-export-short[checked]")

      choose(panel, %{"format" => "short"})
      assert has_element?(panel, "#pdt-export-short[checked]")
      refute has_element?(panel, "#pdt-export-full[checked]")
    end

    test "tampered submits are ignored, never break the tab", %{host: host, panel: panel} do
      run(host, panel, "SELECT id FROM users", [])

      for params <- [
            %{"format" => "xml", "action" => "copy"},
            %{"format" => "short", "action" => "download"},
            %{"format" => %{"a" => 1}}
          ] do
        panel |> element("#pdt-ecto-export") |> render_submit(params)
      end

      render_async(panel)
      refute_push_event(panel, "pdt:export", %{}, 50)
      refute has_element?(panel, "#pdt-disabled-ecto")
      assert has_element?(panel, "#pdt-ecto-export")

      # The tab still works: a real Copy exports the query.
      copy(panel, %{"format" => "full"})

      assert_push_event(panel, "pdt:export", %{payload: %{"queries" => queries}})
      assert Enum.any?(queries, &(&1["sql"] == "SELECT id FROM users"))
    end
  end
end
