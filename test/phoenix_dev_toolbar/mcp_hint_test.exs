defmodule PhoenixDevToolbar.McpHintTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import PhoenixDevToolbar.EnvHelpers
  import Plug.Conn
  import Plug.Test

  alias PhoenixDevToolbar.McpHint
  alias PhoenixDevToolbar.Plug, as: ToolbarPlug
  alias PhoenixDevToolbar.Store

  @opts ToolbarPlug.init([])

  defmodule LoopbackEndpoint do
    @moduledoc false
    def config(:http), do: [ip: {127, 0, 0, 1}, port: 4000]
  end

  defmodule OpenEndpoint do
    @moduledoc false
    def config(:http), do: [ip: {0, 0, 0, 0}, port: 4000]
  end

  defmodule BrokenEndpoint do
    @moduledoc false
    def config(:http), do: :not_a_keyword
  end

  setup do
    Store.reset()
    McpHint.reset()
    level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: level)
      McpHint.reset()
      Store.reset()
    end)
  end

  defp page(endpoint \\ nil) do
    conn =
      :get
      |> conn("/users")
      |> Map.merge(%{scheme: :http, host: "localhost", port: 4000})
      |> put_req_header("accept", "text/html")

    case endpoint do
      nil -> conn
      module -> put_private(conn, :phoenix_endpoint, module)
    end
  end

  defp hit(conn), do: capture_log(fn -> ToolbarPlug.call(conn, @opts) end)

  test "the first tracked request logs the MCP URL, once" do
    assert hit(page()) =~ "[phoenix_dev_toolbar] MCP at http://localhost:4000/__pdt/mcp"
    refute hit(page()) =~ "MCP at"
  end

  test "port 80 is left out of the URL" do
    conn = Map.merge(page(), %{port: 80})
    assert hit(conn) =~ "MCP at http://localhost/__pdt/mcp"
  end

  test "a loopback binding adds the note" do
    log = hit(page(LoopbackEndpoint))
    assert log =~ "listening on 127.0.0.1 only: an MCP URL with another address is refused"
  end

  test "an open binding, a broken config and no endpoint add no note" do
    for endpoint <- [OpenEndpoint, BrokenEndpoint, nil] do
      McpHint.reset()
      log = hit(page(endpoint))
      assert log =~ "MCP at"
      refute log =~ "listening on"
    end
  end

  test "nothing is logged when mcp is off, and the line still comes once it is on" do
    put_app_env(:mcp, false)
    refute hit(page()) =~ "MCP at"
    assert :persistent_term.get({McpHint, :logged}, false) == false

    put_app_env(:mcp, :loopback)
    assert hit(page()) =~ "MCP at"
  end

  test "only a loopback client sets the flag: a remote request leaves it for a local one" do
    remote = %{page() | remote_ip: {192, 168, 1, 20}}
    refute hit(remote) =~ "MCP at"
    assert hit(page()) =~ "MCP at"
    refute hit(page()) =~ "MCP at"
  end

  test "IPv6 loopback and mapped IPv4 loopback clients count as local" do
    for ip <- [{0, 0, 0, 0, 0, 0, 0, 1}, {0, 0, 0, 0, 0, 65_535, 0x7F00, 1}] do
      McpHint.reset()
      assert hit(%{page() | remote_ip: ip}) =~ "MCP at"
    end
  end
end
