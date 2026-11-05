defmodule PdtExamples.ObanTest do
  # The example plugin end to end: a host LiveView emits Oban's insert span,
  # the plugin records it, the panel shows the tab and badge.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhoenixDevToolbar.Collector
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Store

  @endpoint DemoWeb.Endpoint

  defp job(queue),
    do:
      %{} |> Oban.Job.new(worker: "MyApp.Mailer", queue: queue) |> Ecto.Changeset.apply_changes()

  describe "collect/3" do
    test "records an insert with bounded, redacted data, filtered by queue" do
      {:ok, config} = PdtExamples.Oban.init(queues: [:mailers])
      context = %PhoenixDevToolbar.Context{sid: "s", source: :self, config: config}
      event = [:oban, :engine, :insert_job, :stop]

      job = %{job("mailers") | args: %{"password" => "hunter2", "to" => "ada"}}

      assert {:record, %Event{kind: :inserted, data: data}} =
               PdtExamples.Oban.collect(event, {%{duration: 10}, %{job: job}}, context)

      assert %{worker: "MyApp.Mailer", queue: "mailers", state: "available"} = data
      assert data.args =~ "[REDACTED]"
      refute data.args =~ "hunter2"

      assert PdtExamples.Oban.collect(event, {%{duration: 10}, %{job: job("default")}}, context) ==
               :skip
    end

    test "a unique conflict is not counted as a new job; failures color the badge" do
      inserted = Event.new(:oban, :inserted, %{conflict?: false}, at: 0)
      duplicate = Event.new(:oban, :inserted, %{conflict?: true}, at: 0)
      rejected = Event.new(:oban, :rejected, %{}, at: 0)

      summary =
        Enum.reduce([inserted, duplicate, rejected], PdtExamples.Oban.summary_init(nil), fn e,
                                                                                            acc ->
          PdtExamples.Oban.summary_add(acc, e)
        end)

      assert [%{text: "1 job enqueued", level: :error}] = PdtExamples.Oban.badges(summary)
    end

    test "validates its options" do
      assert {:error, message} = PdtExamples.Oban.init(queues: "mailers")
      assert message =~ "queues must be :all or a list"
    end
  end

  describe "in the panel" do
    setup do
      Store.reset()
      Collector.attach(PhoenixDevToolbar.Application.plugins() ++ [PdtExamples.Oban])

      on_exit(fn ->
        Collector.attach(PhoenixDevToolbar.Application.plugins())
        Store.reset()
      end)
    end

    test "shows the jobs a page enqueued and a badge" do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("accept", "text/html")
        |> Plug.Conn.put_req_header("sec-fetch-dest", "document")
        |> get("/demo")

      [sid] =
        conn
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("script[data-pdt-sid]")
        |> LazyHTML.attribute("data-pdt-sid")

      {:ok, host, _html} = live(conn)
      {:ok, panel, _html} = live(build_conn(), "/__pdt/panel?sid=#{sid}")

      render_hook(host, "enqueue", %{"worker" => "MyApp.Welcome", "queue" => "default"})
      send(panel.pid, :pdt_flush)
      _ = render(panel)

      assert has_element?(panel, "#pdt-tab-oban", "Oban")
      assert has_element?(panel, "#pdt-badge-oban-jobs", "1 job enqueued")
      assert has_element?(panel, "#oban-jobs li[id^=oban-job-]", "MyApp.Welcome")
      refute render(panel) =~ "s3cret"
    end
  end
end
