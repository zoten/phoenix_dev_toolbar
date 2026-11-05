# The phoenix_dev_toolbar dev harness (ADR 06): a tiny Phoenix app in one file.
#
#     mix dev              # http://localhost:4000
#     PORT=4001 mix dev
#
# Every page exercises a toolbar panel. The SQLite database lives in
# tmp/dev.sqlite3 and is recreated on every boot.

port = String.to_integer(System.get_env("PORT", "4000"))
database = Path.expand("tmp/dev.sqlite3", __DIR__)

Application.put_env(:phoenix_dev_toolbar, Demo.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: port],
  server: true,
  secret_key_base: String.duplicate("pdt-dev-harness-secret-", 4),
  live_view: [signing_salt: "pdt-dev-lv-salt"],
  pubsub_server: Demo.PubSub,
  check_origin: false,
  debug_errors: true
)

Application.put_env(:phoenix_dev_toolbar, Demo.Repo, database: database, stacktrace: true)
Application.put_env(:phoenix_dev_toolbar, :repos, [Demo.Repo])

defmodule Demo.Repo do
  @moduledoc false
  use Ecto.Repo, otp_app: :phoenix_dev_toolbar, adapter: Ecto.Adapters.SQLite3
end

defmodule Demo.Migration do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:users) do
      add(:name, :string)
      add(:email, :string)
    end

    create table(:posts) do
      add(:title, :string)
      add(:user_id, references(:users))
    end

    create table(:clicks) do
      add(:label, :string)
    end
  end
end

defmodule Demo.User do
  @moduledoc false
  use Ecto.Schema

  schema "users" do
    field(:name, :string)
    field(:email, :string)
  end
end

defmodule Demo.Post do
  @moduledoc false
  use Ecto.Schema

  schema "posts" do
    field(:title, :string)
    belongs_to(:user, Demo.User)
  end
end

defmodule Demo.Click do
  @moduledoc false
  use Ecto.Schema

  schema "clicks" do
    field(:label, :string)
  end
end

defmodule Demo.Seeds do
  @moduledoc false
  alias Demo.Post
  alias Demo.Repo
  alias Demo.User

  @names ~w(Ada Grace Alan Barbara Edsger Margaret Dennis Radia)

  def run do
    users =
      for name <- @names,
          do: Repo.insert!(%User{name: name, email: "#{String.downcase(name)}@example.com"})

    for {user, index} <- Enum.with_index(users), n <- 1..3 do
      Repo.insert!(%Post{title: "#{user.name}'s post ##{index * 3 + n}", user_id: user.id})
    end
  end
end

defmodule Demo.Layouts do
  @moduledoc false
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>phoenix_dev_toolbar demo</title>
        <link rel="icon" href="data:," />
        <style>
          body { font: 15px/1.5 system-ui, sans-serif; max-width: 52rem; margin: 2rem auto; padding: 0 1rem 6rem; color: #1d2129; }
          nav { display: flex; gap: 1rem; padding-bottom: 1rem; border-bottom: 1px solid #e3e6eb; }
          button { font: inherit; padding: .3rem .8rem; margin-right: .5rem; cursor: pointer; }
          code { background: #f3f4f6; padding: 0 .3rem; border-radius: 3px; }
        </style>
        <script src="/assets/phoenix/phoenix.min.js">
        </script>
        <script src="/assets/lv/phoenix_live_view.min.js">
        </script>
        <script>
          window.addEventListener("DOMContentLoaded", () => {
            const csrfToken = document.querySelector("meta[name='csrf-token']").content
            window.liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {params: {_csrf_token: csrfToken}})
            window.liveSocket.connect()
          })
        </script>
      </head>
      <body>
        <nav>
          <.link navigate="/">Users</.link>
          <.link navigate="/posts">Posts (N+1)</.link>
          <.link navigate="/counter">Events</.link>
          <.link navigate="/tasks">Task.async</.link>
          <.link navigate="/components">Components</.link>
          <.link navigate="/assigns">Assigns</.link>
          <a href="/plain">Dead page</a>
        </nav>
        {@inner_content}
      </body>
    </html>
    """
  end
end

defmodule Demo.UsersLive do
  @moduledoc false
  use Phoenix.LiveView

  import Ecto.Query

  alias Demo.Repo
  alias Demo.User

  def mount(_params, _session, socket) do
    {:ok, assign(socket, users: Repo.all(from(u in User, order_by: u.name)))}
  end

  def render(assigns) do
    ~H"""
    <h1>Users</h1>
    <p>One query on the dead render, one on the connected mount: the toolbar shows both.</p>
    <ul>
      <li :for={user <- @users}>{user.name} <code>{user.email}</code></li>
    </ul>
    """
  end
end

defmodule Demo.PostsLive do
  @moduledoc false
  use Phoenix.LiveView

  alias Demo.Post
  alias Demo.Repo
  alias Demo.User

  def mount(_params, _session, socket), do: {:ok, socket}

  # A live patch: same LiveView, same toolbar session, new queries.
  def handle_params(params, _uri, socket) do
    preload? = params["preload"] == "1"
    {:noreply, assign(socket, preload?: preload?, posts: load(preload?))}
  end

  defp load(true), do: Post |> Repo.all() |> Repo.preload(:user)

  # The classic N+1: one query per post for its author.
  defp load(false),
    do: for(post <- Repo.all(Post), do: %{post | user: Repo.get!(User, post.user_id)})

  def render(assigns) do
    ~H"""
    <h1>Posts</h1>
    <p :if={!@preload?}>
      Loads every author with its own query (N+1).
      <.link patch="/posts?preload=1">Use a preload</.link>
    </p>
    <p :if={@preload?}>
      Two queries with <code>Repo.preload/2</code>. <.link patch="/posts">Back to N+1</.link>
    </p>
    <ul>
      <li :for={post <- @posts}>{post.title} by {post.user.name}</li>
    </ul>
    """
  end
end

defmodule Demo.CounterLive do
  @moduledoc false
  use Phoenix.LiveView

  alias Demo.Click
  alias Demo.Repo

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, clicks: Repo.aggregate(Click, :count))}

  def handle_event("click", _params, socket), do: {:noreply, record(socket, "fast")}

  def handle_event("slow", _params, socket) do
    Process.sleep(400)
    {:noreply, record(socket, "slow")}
  end

  def handle_event("fail", _params, socket) do
    _ = Repo.query("SELECT * FROM no_such_table")
    {:noreply, socket}
  end

  defp record(socket, label) do
    Repo.insert!(%Click{label: label})
    assign(socket, clicks: Repo.aggregate(Click, :count))
  end

  def render(assigns) do
    ~H"""
    <h1>Events</h1>
    <p>Each click runs queries inside <code>handle_event/3</code>: they show up live.</p>
    <button id="click" phx-click="click">Click</button>
    <button id="slow" phx-click="slow">Slow handler (400 ms)</button>
    <button id="fail" phx-click="fail">Failing query</button>
    <p>{@clicks} clicks so far.</p>
    """
  end
end

defmodule Demo.TasksLive do
  @moduledoc false
  use Phoenix.LiveView

  import Ecto.Query

  alias Demo.Repo

  @tables ~w(users posts clicks)

  # Queries run by Task.async_stream children are attributed through $callers.
  def mount(_params, _session, socket) do
    counts =
      @tables
      |> Task.async_stream(fn table -> {table, Repo.aggregate(from(t in table), :count)} end)
      |> Enum.map(fn {:ok, pair} -> pair end)

    {:ok, assign(socket, counts: counts)}
  end

  def render(assigns) do
    ~H"""
    <h1>Task.async</h1>
    <p>These counts come from <code>Task.async_stream/2</code> children: look for the "task" tag.</p>
    <ul>
      <li :for={{table, count} <- @counts}><code>{table}</code>: {count}</li>
    </ul>
    """
  end
end

defmodule Demo.UserCard do
  @moduledoc false
  # A stateful LiveComponent: its update, handle_event and render show up in the
  # LiveView tab, folded into the parent render.
  use Phoenix.LiveComponent

  def mount(socket), do: {:ok, assign(socket, likes: 0, refreshed: 0)}

  def update(%{refresh: true}, socket), do: {:ok, update(socket, :refreshed, &(&1 + 1))}
  def update(assigns, socket), do: {:ok, assign(socket, user: assigns.user)}

  def handle_event("like", _params, socket), do: {:noreply, update(socket, :likes, &(&1 + 1))}

  def render(assigns) do
    ~H"""
    <li id={"card-#{@user.id}"}>
      {@user.name}
      <button id={"like-#{@user.id}"} phx-click="like" phx-target={@myself}>Like ({@likes})</button>
      <small>refreshed {@refreshed}x</small>
    </li>
    """
  end
end

defmodule Demo.NestedLive do
  @moduledoc false
  # A nested LiveView (`live_render/3`): its own process, same toolbar session.
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, assign(socket, pings: 0)}

  def handle_event("ping", _params, socket), do: {:noreply, update(socket, :pings, &(&1 + 1))}

  def render(assigns) do
    ~H"""
    <p>Nested LiveView: <button id="ping" phx-click="ping">Ping ({@pings})</button></p>
    """
  end
end

defmodule Demo.ComponentsLive do
  @moduledoc false
  use Phoenix.LiveView

  import Ecto.Query

  alias Demo.Repo
  alias Demo.User

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, users: Repo.all(from(u in User, order_by: u.name)))}

  # send_update/3 renders the components outside a LiveView render.
  def handle_event("refresh", _params, socket) do
    for user <- socket.assigns.users, do: send_update(Demo.UserCard, id: user.id, refresh: true)
    {:noreply, socket}
  end

  def handle_event("highlight", _params, socket),
    do: {:noreply, push_event(socket, "highlight", %{id: "cards"})}

  def render(assigns) do
    ~H"""
    <h1>Components</h1>
    <p>LiveComponents, a nested LiveView and a <code>push_event</code>: see the LiveView tab.</p>
    <button id="refresh" phx-click="refresh">send_update all</button>
    <button id="highlight" phx-click="highlight">push_event "highlight"</button>
    <ul id="cards">
      <.live_component :for={user <- @users} module={Demo.UserCard} id={user.id} user={user} />
    </ul>
    {live_render(@socket, Demo.NestedLive, id: "nested")}
    """
  end
end

defmodule Demo.AssignsLive do
  @moduledoc false
  # Large and sensitive assigns, a per keystroke diff and a slow handle_params.
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       query: "",
       api_token: "demo-token-never-shown",
       rows: Enum.map(1..2_000, &%{id: &1, label: "row #{&1}"}),
       settings: %{theme: "light", password: "hunter2", nested: %{deep: %{deeper: [1, 2, 3]}}}
     )}
  end

  def handle_params(params, _uri, socket) do
    slow? = params["slow"] == "1"
    maybe_sleep(slow?)
    {:noreply, assign(socket, slow?: slow?)}
  end

  defp maybe_sleep(true), do: Process.sleep(250)
  defp maybe_sleep(false), do: :ok

  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, query: q)}

  def render(assigns) do
    ~H"""
    <h1>Assigns</h1>
    <p>
      2000 rows, a nested map and redacted keys (<code>api_token</code>, <code>password</code>).
      <.link :if={!@slow?} patch="/assigns?slow=1">Slow handle_params (250 ms)</.link>
      <.link :if={@slow?} patch="/assigns">Back</.link>
    </p>
    <form id="search" phx-change="search">
      <input name="q" value={@query} placeholder="Type to change one assign" autocomplete="off" />
    </form>
    <p>Query: <code>{@query}</code>, {length(@rows)} rows.</p>
    """
  end
end

defmodule Demo.PlainPage do
  @moduledoc false
  @behaviour Plug

  import Ecto.Query

  def init(opts), do: opts

  # A dead page, no LiveView: the toolbar shows the request and its queries.
  def call(conn, _opts) do
    count = Demo.Repo.aggregate(from(p in "posts"), :count)

    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, """
    <!DOCTYPE html>
    <html><head><link rel="icon" href="data:,"></head><body style="font: 15px system-ui; margin: 2rem">
      <h1>Dead page</h1>
      <p>A plain Plug response with #{count} posts counted. <a href="/">Back to the LiveViews</a></p>
    </body></html>
    """)
  end
end

defmodule Demo.Router do
  @moduledoc false
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Demo.Layouts, :root}
    plug :protect_from_forgery
  end

  scope "/" do
    pipe_through :browser

    live_session :demo do
      live "/", Demo.UsersLive
      live "/posts", Demo.PostsLive
      live "/counter", Demo.CounterLive
      live "/tasks", Demo.TasksLive
      live "/components", Demo.ComponentsLive
      live "/assigns", Demo.AssignsLive
    end

    get "/plain", Demo.PlainPage, []
  end
end

defmodule Demo.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :phoenix_dev_toolbar

  @session [store: :cookie, key: "_pdt_demo", signing_salt: "pdt-demo-salt"]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]]

  plug Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/assets/lv",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  # In a host app this sits under `if code_reloading? do`, before the session plug.
  plug PhoenixDevToolbar.Plug
  plug Plug.RequestId
  plug Plug.Parsers, parsers: [:urlencoded, :multipart, :json], json_decoder: Jason
  plug Plug.Session, @session
  plug Demo.Router
end

File.mkdir_p!(Path.dirname(database))
for file <- Path.wildcard(database <> "*"), do: File.rm!(file)

{:ok, _} =
  Supervisor.start_link([Demo.Repo, {Phoenix.PubSub, name: Demo.PubSub}, Demo.Endpoint],
    strategy: :one_for_one
  )

Ecto.Migrator.run(Demo.Repo, [{1, Demo.Migration}], :up, all: true, log: false)
Demo.Seeds.run()

# The toolbar started before Demo.Repo existed: attach again to pick up its queries.
PhoenixDevToolbar.Collector.attach(PhoenixDevToolbar.Application.plugins())

IO.puts("phoenix_dev_toolbar harness running at http://localhost:#{port}")
Process.sleep(:infinity)
