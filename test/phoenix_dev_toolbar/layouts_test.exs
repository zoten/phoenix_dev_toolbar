defmodule PhoenixDevToolbar.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixDevToolbar.Layouts

  defp render_root(request_path) do
    conn = %Plug.Conn{
      request_path: request_path,
      private: %{phoenix_dev_toolbar_panel: %{path: "/__pdt", live_socket_path: "/live"}}
    }

    (&Layouts.root/1)
    |> render_component(conn: conn, inner_content: "")
    |> LazyHTML.from_document()
  end

  # `//__pdt/panel` reaches the panel too; a base derived from the request path
  # would be `//__pdt`, a protocol relative URL to another host.
  test "builds asset URLs from the configured path, never from the request path" do
    for request_path <- ["/__pdt/panel", "//__pdt/panel", "/__pdt/panel/"] do
      document = render_root(request_path)

      assert [_] =
               document
               |> LazyHTML.query(~s(script[src="/__pdt/assets/panel.js"]))
               |> Enum.to_list()

      assert [_] =
               document
               |> LazyHTML.query(~s(link[href="/__pdt/assets/panel.css"]))
               |> Enum.to_list()
    end
  end
end
