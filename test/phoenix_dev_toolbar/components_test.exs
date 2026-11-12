defmodule PhoenixDevToolbar.ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixDevToolbar.Components
  alias PhoenixDevToolbar.Event

  doctest Components

  describe "stack_args/1" do
    defp rendered(data) do
      render_component(&Components.stack_args/1, data: data)
    end

    test "renders the arguments of the frames that carried them, escaped" do
      html =
        rendered(%{
          stacktrace: ["A.f/1", "B.g/0"],
          stack_args: ["[\"<script>x</script>\"]", nil]
        })

      document = LazyHTML.from_fragment(html)
      assert [_] = Enum.to_list(LazyHTML.query(document, "details[data-pdt-stack-args]"))
      assert [_] = Enum.to_list(LazyHTML.query(document, "details[data-pdt-stack-args] dd"))
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;x&lt;/script&gt;"
    end

    test "renders nothing without them" do
      assert rendered(%{stacktrace: ["A.f/1"]}) =~ ~r/\A\s*\z/
    end
  end

  describe "titles readable by screen readers" do
    defp sr_texts(html, selector) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector <> " .pdt-sr-only")
      |> Enum.map(&LazyHTML.text/1)
    end

    test "a titled badge, dropped and trimmed carry their title as sr-only text" do
      html =
        render_component(&Components.summary_bar/1,
          badges: [
            %{id: "a", level: :ok, text: "1 query", title: "Queries of the page"},
            %{id: "b", level: :ok, text: "plain"}
          ],
          dropped: 3,
          trimmed: 2
        )

      assert sr_texts(html, "#pdt-badge-a") == [": Queries of the page"]
      assert sr_texts(html, "#pdt-badge-b") == []
      assert [": Events over" <> _] = sr_texts(html, "#pdt-badge-dropped")
      assert [": The oldest events" <> _] = sr_texts(html, "#pdt-badge-trimmed")
    end

    defp query_html(data, sid) do
      event = %Event{
        sid: sid,
        seq: 1,
        plugin: :ecto,
        kind: :query,
        at: 0,
        duration: 10,
        data:
          Map.merge(
            %{sql: "SELECT 1", source: nil, result: {:ok, 1}, caller?: false, times: %{}},
            data
          )
      }

      render_component(&Components.query_row/1, id: "q1", event: event, root: "root")
    end

    test "phase tags explain HTTP and live" do
      assert [": Ran during the HTTP request" <> _] =
               sr_texts(query_html(%{}, "root"), "[data-pdt-phase=http]")

      assert [": Ran in the connected LiveView"] =
               sr_texts(query_html(%{}, "other"), "[data-pdt-phase=live]")
    end

    test "task, framework and N+1 tags explain themselves" do
      html =
        query_html(
          %{
            caller?: true,
            n_plus_one?: true,
            sql: ~s(SELECT 1 FROM "schema_migrations"),
            stacktrace: ["Phoenix.Ecto.CheckRepoStatus.call/2 (lib/x.ex:1)"]
          },
          "root"
        )

      assert Enum.any?(
               sr_texts(html, ".pdt-tag"),
               &String.starts_with?(&1, ": Run by a Task.async")
             )

      assert [": A framework query" <> _] = sr_texts(html, "#pdt-noise-1")
      assert [": Repeated in one callback" <> _] = sr_texts(html, ".pdt-tag--warn")
    end
  end
end
