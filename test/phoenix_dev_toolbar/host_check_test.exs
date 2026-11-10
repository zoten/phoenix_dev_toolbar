defmodule PhoenixDevToolbar.HostCheckTest do
  # Changes the application env (`allowed_hosts:`).
  use ExUnit.Case, async: false

  import PhoenixDevToolbar.EnvHelpers

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
    delete_app_env(:allowed_hosts)
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
    put_app_env(:allowed_hosts, ["myapp.test", ".lan"])

    assert HostCheck.allowed?(conn("myapp.test"))
    assert HostCheck.allowed?(conn("box.lan"))
    refute HostCheck.allowed?(conn("other.test"))
  end

  test "the export path is refused for a refused host too" do
    conn =
      Phoenix.ConnTest.build_conn(:get, "/__pdt/export/ecto.json?format=short")
      |> Map.put(:host, "evil.example")
      |> DemoWeb.Endpoint.call([])

    assert conn.status == 403
    assert conn.halted
  end

  describe "log_refused/1" do
    @key {PhoenixDevToolbar.HostCheck, :logged}

    setup do
      :persistent_term.erase(@key)
      on_exit(fn -> :persistent_term.erase(@key) end)
    end

    test "logs each host once" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for host <- ["a.example", "a.example", "b.example", "a.example"],
              do: HostCheck.log_refused(host)
        end)

      assert length(Regex.scan(~r/refused the panel for host "a\.example"/, log)) == 1
      assert length(Regex.scan(~r/refused the panel for host "b\.example"/, log)) == 1
    end

    test "names at most 10 distinct hosts" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for n <- 1..15, do: HostCheck.log_refused("h#{n}.example")
        end)

      assert length(Regex.scan(~r/refused the panel for host/, log)) == 10
      refute log =~ "h11.example"
    end
  end

  test "the plug refuses the panel for a refused host, and says how to allow it" do
    conn =
      Phoenix.ConnTest.build_conn(:get, "/__pdt/panel?sid=x")
      |> Map.put(:host, "evil.example")
      |> DemoWeb.Endpoint.call([])

    assert conn.status == 403
    assert conn.resp_body =~ ~s(allowed_hosts: ["evil.example"])
    assert conn.resp_body =~ ~s(id="pdt-refused")

    # The host is the attacker's to choose: escaped.
    conn =
      Phoenix.ConnTest.build_conn(:get, "/__pdt/panel?sid=x")
      |> Map.put(:host, "<b>x</b>.example")
      |> DemoWeb.Endpoint.call([])

    refute conn.resp_body =~ "<b>"
  end
end
