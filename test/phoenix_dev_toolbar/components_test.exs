defmodule PhoenixDevToolbar.ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixDevToolbar.Components

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
      assert [_] = Enum.to_list(LazyHTML.query(document, "details.pdt-stack-args"))
      assert [_] = Enum.to_list(LazyHTML.query(document, "details.pdt-stack-args dd"))
      refute html =~ "<script>"
    end

    test "renders nothing without them" do
      assert rendered(%{stacktrace: ["A.f/1"]}) =~ ~r/\A\s*\z/
    end
  end
end
