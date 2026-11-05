defmodule PhoenixDevToolbar.ShellTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Plugins
  alias PhoenixDevToolbar.Shell
  alias PhoenixDevToolbar.TestPlugins.Echo
  alias PhoenixDevToolbar.TestPlugins.Tabbed

  @plugins [{Plugins.Ecto, %{repos: []}}, {Echo, []}, {Tabbed, %{prefix: "x"}}]

  test "tabs are the plugins with a panel, in configuration order" do
    assert [
             %{id: "ecto", name: "Ecto", panel: PhoenixDevToolbar.Panels.Ecto},
             %{id: "tabbed", name: "Tabbed", config: %{prefix: "x"}}
           ] = @plugins |> Shell.new() |> Shell.tabs()
  end

  test "routes events to their plugin's tab, oldest first, and drops the others" do
    echo = Event.new(:echo, :echo, %{}, at: 0)
    first = Event.new(:tabbed, :echo, %{n: 1}, at: 0)
    second = Event.new(:tabbed, :echo, %{n: 2}, at: 0)
    client = Event.new(:client, :client, %{}, at: 0)

    assert @plugins |> Shell.new() |> Shell.route([first, echo, client, second]) ==
             %{"tabbed" => [first, second]}
  end

  test "folds summaries incrementally and resets them for a new page" do
    shell = @plugins |> Shell.new() |> Shell.fold([Event.new(:tabbed, :echo, %{}, at: 0)])

    assert [%{id: "queries", text: "0 queries" <> _}, %{id: "tabbed", text: "1 echoes"}] =
             Shell.badges(shell)

    assert [_queries, %{text: "0 echoes"}] = shell |> Shell.reset([]) |> Shell.badges()
  end
end
