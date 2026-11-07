defmodule DemoWeb.LoaderLive do
  @moduledoc false
  # A host LiveView whose mount loads its data in Task.async children, on the
  # SQLite test repo: queries in both the dead render and the connected mount.
  use Phoenix.LiveView

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    names =
      for id <- [1, 2] do
        Task.async(fn ->
          DemoWeb.SQLiteRepo.query!("SELECT name FROM users WHERE id = ?", [id])
        end)
      end
      |> Task.await_many()
      |> Enum.flat_map(& &1.rows)

    {:ok, assign(socket, :names, names)}
  end

  @impl Phoenix.LiveView
  def render(assigns), do: ~H"<p>{length(@names)} users</p>"
end
