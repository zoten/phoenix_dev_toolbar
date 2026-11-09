defmodule PhoenixDevToolbar.HostCheckTest do
  # Changes the application env (`allowed_hosts:`).
  use ExUnit.Case, async: false

  alias PhoenixDevToolbar.HostCheck

  defp conn(host, endpoint \\ nil) do
    conn = Plug.Test.conn(:get, "/__pdt/panel")
    conn = %{conn | host: host}

    case endpoint do
      nil -> conn
      endpoint -> Plug.Conn.put_private(conn, :phoenix_endpoint, endpoint)
    end
  end

  setup do
    previous = Application.fetch_env(:phoenix_dev_toolbar, :allowed_hosts)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_dev_toolbar, :allowed_hosts, value)
        :error -> Application.delete_env(:phoenix_dev_toolbar, :allowed_hosts)
      end
    end)

    Application.delete_env(:phoenix_dev_toolbar, :allowed_hosts)
  end

  test "IP literals and localhost names cannot be rebound: allowed" do
    for host <- [
          "127.0.0.1",
          "192.168.1.20",
          "[::1]",
          "::1",
          "localhost",
          "app.localhost",
          "LOCALHOST"
        ],
        do: assert(HostCheck.allowed?(conn(host)), host)
  end

  test "any other name is refused: a rebound attacker domain looks like this" do
    refute HostCheck.allowed?(conn("evil.example"))
    refute HostCheck.allowed?(conn("localhost.evil.example"))
  end

  test "the endpoint's own url host is allowed" do
    assert HostCheck.allowed?(conn("myapp.example", PhoenixDevToolbar.HostEndpoint))
    refute HostCheck.allowed?(conn("other.example", PhoenixDevToolbar.HostEndpoint))
  end

  test "allowed_hosts: exact names, and suffixes starting with a dot" do
    Application.put_env(:phoenix_dev_toolbar, :allowed_hosts, ["myapp.test", ".lan"])

    assert HostCheck.allowed?(conn("myapp.test"))
    assert HostCheck.allowed?(conn("box.lan"))
    refute HostCheck.allowed?(conn("other.test"))
  end

  test "the plug refuses the panel for a refused host, and says how to allow it" do
    conn =
      Phoenix.ConnTest.build_conn(:get, "/__pdt/panel?sid=x")
      |> Map.put(:host, "evil.example")
      |> DemoWeb.Endpoint.call([])

    assert conn.status == 403
    assert conn.resp_body =~ "allowed_hosts"
  end
end
