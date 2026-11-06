# Writing a plugin

A plugin adds a tab and badges to the toolbar. The built-in Ecto, Request and
LiveView panels are plugins too, written against the same API. This guide
builds one step by step; the complete example is the Oban plugin in the
repository's `examples/oban` folder.

> The plugin API is unstable before 1.0: changes are listed in the CHANGELOG.

## Where the module lives

The toolbar is a dev only dependency (`only: :dev`): in `:prod` (and `:test`)
`PhoenixDevToolbar.Plugin` does not exist, so a plugin module in `lib/` breaks
those builds. Keep plugins in a directory compiled in `:dev` only:

```elixir
# mix.exs
def project do
  [elixirc_paths: elixirc_paths(Mix.env()), ...]
end

defp elixirc_paths(:dev), do: ["lib", "dev"]
defp elixirc_paths(_env), do: ["lib"]
```

and put `MyApp.Toolbar.Jobs` in `dev/toolbar/jobs.ex`, registered from
`config/dev.exs`. A plugin published as its own package declares the toolbar
as a dependency and is installed `only: :dev` as well.

## Where your code runs

A plugin has three parts, each running in a different place:

| Part | Callbacks | Runs in |
|---|---|---|
| Collection | `init/1`, `telemetry_events/1`, `collect/3` | the host app's processes |
| Summary | `summary_init/1`, `summary_add/2`, `badges/1` | the toolbar panel |
| Tab | a `PhoenixDevToolbar.Panel` LiveComponent | the toolbar panel |

`collect/3` is the one to be careful with. It runs **inside the host process
that emitted the telemetry event**: a request, a LiveView, a process calling
your Repo. The toolbar only calls it for processes it tracks (the page you are
looking at and its `Task.async` children), but there it runs on every event:

- Keep it cheap and pure: no `GenServer.call`, no I/O, no `Process.sleep`.
- Bound everything you keep. Use `PhoenixDevToolbar.Truncate`: `string/2`
  (binaries only), `inspect_value/2`, and `preview/2` for user data such as
  params or job args: it redacts keys such as `password` and cuts what it does
  not walk, however deep. Never store a whole struct, a socket or a conn.
- Never create atoms from runtime data.
- Never assume a metadata field is present or has a type: a value you did not
  expect is better shown as `inspect_value/1` than raised on.

If `collect/3` raises, throws, exits or returns anything other than
`{:record, event}` or `:skip`, the toolbar disables the plugin (it is
*quarantined*), logs the error once and shows it in the plugin's tab with a
**Re-enable** button (in the summary bar for a plugin without a tab). The host
app and the other plugins keep working.

## Attribution: what counts as "the page"

An event belongs to a page when it is emitted by a process the toolbar tracks:
the request that rendered the page, its LiveView, or a `$callers` child of
them (`Task.async`, `Task.async_stream`). `Context.source` tells which:
`:self` or `:caller`.

Work done in other processes is not attributed: a GenServer the LiveView calls,
a PubSub subscriber, a job runner. For Oban, the *insert* of a job runs in the
caller (the LiveView that enqueued it), so it shows; the job's *execution*
runs in Oban's queue processes, which belong to no page, so it does not
(except with `testing: :inline`, where jobs run in the caller).

## 1. Collection

```elixir
defmodule MyApp.Toolbar.Jobs do
  use PhoenixDevToolbar.Plugin, id: :jobs, name: "Jobs"

  alias PhoenixDevToolbar.{Context, Event, Truncate}

  # Runs once, when the toolbar starts: validate options here.
  @impl PhoenixDevToolbar.Plugin
  def init(opts) do
    case Keyword.get(opts, :queues, :all) do
      :all -> {:ok, %{queues: :all}}
      queues when is_list(queues) -> {:ok, %{queues: Enum.map(queues, &to_string/1)}}
      other -> {:error, "queues must be :all or a list, got: #{inspect(other)}"}
    end
  end

  @impl PhoenixDevToolbar.Plugin
  def telemetry_events(_config), do: [[:oban, :engine, :insert_job, :stop]]

  # Runs in the host process. The config is the one init/1 returned.
  @impl PhoenixDevToolbar.Plugin
  def collect(_event, {measurements, %{job: job}}, %Context{config: config}) do
    case config.queues == :all or job.queue in config.queues do
      true ->
        data = %{worker: Truncate.inspect_value(job.worker), args: Truncate.preview(job.args, 512)}
        {:record, Event.new(:jobs, :inserted, data, duration: measurements[:duration])}

      false ->
        :skip
    end
  end

  def collect(_event, _payload, _context), do: :skip
end
```

- `id` is stored in every event (`Event.plugin`, set by the toolbar to your
  plugin's id) and names the tab (`#pdt-tab-jobs`); it must be unique among
  the configured plugins.
- `Event.new/4` takes the plugin id, a `kind` of your choosing, the `data` map
  (already bounded: it is stored as is) and an optional `:duration` in native
  time units, as `:telemetry` reports it.
- Return `:skip` for events you do not want.

Register it in `config/dev.exs`:

```elixir
config :phoenix_dev_toolbar,
  plugins: [:defaults, {MyApp.Toolbar.Jobs, queues: [:mailers]}]
```

An invalid entry (a module that does not implement the behaviour, an `init/1`
returning an error, malformed event names, half of the summary callbacks) is
logged and skipped: your app always boots.

## 2. Summary badges

Badges are shown in the collapsed bar. They are folded event by event in the
panel, so they keep counting when the oldest events are trimmed from the
buffer (each plugin keeps its last 500 events per session; a LiveView page
has two sessions, its request and its LiveView).

```elixir
  @impl PhoenixDevToolbar.Plugin
  def summary_init(_config), do: 0

  @impl PhoenixDevToolbar.Plugin
  def summary_add(count, %Event{kind: :inserted}), do: count + 1
  def summary_add(count, _event), do: count

  @impl PhoenixDevToolbar.Plugin
  def badges(0), do: []
  def badges(count), do: [%{id: "jobs", text: "#{count} jobs", level: :info}]
```

Define all three callbacks or none. A badge that is not well formed is
dropped, and an error in any of the three disables the plugin in the panel,
like an error in its tab. A badge is a map with `id` (the DOM id
becomes `pdt-badge-<id>`: start it with your plugin's id), `text`, `level`
(`:ok`, `:info`, `:warn`, `:error`) and an optional `title` tooltip.

## 3. The tab

`panel/0` returns a LiveComponent that does `use PhoenixDevToolbar.Panel`:

```elixir
  @impl PhoenixDevToolbar.Plugin
  def panel, do: MyApp.Toolbar.JobsPanel
```

```elixir
defmodule MyApp.Toolbar.JobsPanel do
  use PhoenixDevToolbar.Panel

  alias PhoenixDevToolbar.Panel

  # Events have no :id field: DOM ids come from the unique seq.
  @impl Phoenix.LiveComponent
  def mount(socket), do: {:ok, stream_configure(socket, :jobs, dom_id: &"jobs-#{&1.seq}")}

  # A new page (the panel opened, live navigation): every stored event.
  @impl Panel
  def handle_reset(events, socket), do: stream(socket, :jobs, events, reset: true, limit: -500)

  # New events since, oldest first.
  @impl Panel
  def handle_events(events, socket),
    do: Enum.reduce(events, socket, &stream_insert(&2, :jobs, &1, limit: -500))

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <ul id="jobs" class="pdt-list" phx-update="stream">
      <li id="jobs-empty" class="pdt-list__empty">No jobs yet.</li>
      <li :for={{id, event} <- @streams.jobs} id={id} class="pdt-row">
        <code>{event.data.worker}</code>
        <span class="pdt-time">{Panel.duration(event.duration)}</span>
      </li>
    </ul>
    """
  end
end
```

- Keep events in **streams**, never in plain assigns: a page can produce
  thousands.
- The toolbar assigns `@config`, `@page` (`@page.root` is the page's request
  sid), `@shown?` (the tab is selected) and `@visible?` (the panel is open and
  the browser tab visible). `handle_props/1` runs when one of them changes:
  use it to start or stop work that only matters while someone looks.
- Everything a LiveComponent can do works: `handle_event/3` with
  `phx-target={@myself}`, `start_async/3` and `handle_async/3` for slow reads.
  For timers, `PhoenixDevToolbar.Panel.send_after/4` delivers a message to
  `handle_info/2`. Do not define `update/2` or `update_many/1`: the toolbar
  defines them.
- Style with the panel's classes: `pdt-list`, `pdt-row`, `pdt-row__head`,
  `pdt-row__meta`, `pdt-tag`, `pdt-badge`, `pdt-time`, `pdt-error`,
  `pdt-empty`, `pdt-hint`, `pdt-button`. The panel lives in its own iframe:
  your markup can never break the host page, and the panel stylesheet is the
  only one loaded.
- DOM ids must be unique in the whole panel: prefix them with your plugin id.

An exception in the tab's code (its callbacks, `render/1` and its template,
`mount/1`) disables the tab only, with the error and a Re-enable button. The
template is checked by rendering it once more behind that boundary; a template
that nests live components is not checked, and an error there still breaks the
panel.

## Testing a plugin

- Unit test `collect/3` with the metadata shape the library really emits:
  read it in the library's source (`deps/`), not from memory.
- Unit test the summary callbacks: they are pure functions.
- To test against the toolbar, install it `only: [:dev, :test]` and compile
  `dev/` in `:test` too.
- The whole path (a page of your app, the injected sid, the panel at
  `/__pdt/panel?sid=<sid>`) needs `PhoenixDevToolbar.Plug` in the test
  endpoint, which usually sits under `code_reloading?` and is off in tests:
  check it by hand in `mix phx.server` instead. The toolbar's own tests
  (`test/examples/oban_test.exs`) show the full path against a test endpoint.
