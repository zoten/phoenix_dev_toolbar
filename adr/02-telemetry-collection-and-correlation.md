# ADR 02: Telemetry Collection and Correlation

**Status:** Implemented (2026-11-05)  
**Area:** collection  
**Related:** [ADR 03](./03-event-storage.md) (where events go), [ADR 05](./05-plugin-behaviour.md) (plugins declare events)

## Context

We need to know which query, callback or render belongs to which page, without
touching the host's code and without slowing down processes we do not track.
`:telemetry` handlers run synchronously inside the process that emits the event,
which is both the opportunity (we know `self()`) and the risk (we are on the
host's hot path).

## Decision

**Session id (`sid`)**: a random, URL-safe id identifying one page view.

- `PhoenixDevToolbar.Plug` assigns a sid to every HTML request, stores it in the
  request process dictionary (`:pdt_sid`) and in `conn.private`, and embeds it in
  the injected loader (ADR 04).
- The LiveView `socket.id` (`"phx-" <> random`) is generated during the dead render,
  signed into the session and reused by the connected mount, and it is the `id` of the
  `[data-phx-main]` element. So on `[:phoenix, :live_view, :mount, :start]`:
  - in the request process (`connected?` false, sid in pdict) we index `socket.id -> sid`;
  - in the LiveView process we look up `socket.id` and put the sid in the LiveView pdict.
  No help from the loader is needed to correlate the first page.
- The `socket.id` survives live navigation: the client clones the main element (same
  `id`) and rejoins with its session token, and `Session.authorize_root_redirect/2` only
  swaps the view. So a connected mount whose `socket.id` maps to an existing LiveView
  session is either:
  - a **rejoin** (reconnect on a new transport, or crash rejoin on the same one): same
    view and path, previous owner no longer alive. It claims the session, re-indexing
    owner and transport (ADR 03);
  - otherwise **live navigation** (or a duplicated tab): a new LiveView session with
    `parent` set to the existing one. Re-mounting the same view and path after the old
    process died is indistinguishable from a rejoin and continues the same session.
- A connected mount with an unknown `socket.id` (its dead render was not tracked) gets a
  session whose `parent` is the newest sid of its `socket.transport_pid` (one transport
  per browser tab). The panel follows the tab through `{:pdt_session, sid}` notifications.
- Nested LiveViews (`live_render`, non sticky) run in their own process and share the
  sid of `socket.parent_pid`. Sticky LiveViews get their own session that is never
  indexed as the tab's latest, since they survive navigation.
- The toolbar's own LiveViews (any view under `PhoenixDevToolbar.`) are never tracked.
- `PhoenixDevToolbar.Tracker` implements these rules; it runs inside the collector's
  mount `:start` handler before any plugin sees the event, so plugins always find the
  sid already set. New LiveView sessions are announced with `{:pdt_session, sid}` to
  the subscribers of the parent sid and of the transport (`PhoenixDevToolbar.Notify`).

**Attribution** (inside the handler, in this order):

1. `Process.get(:pdt_sid)`: tracked request or LiveView process.
2. `Process.get(:"$callers")`: look up the callers in a `pid -> sid` ETS index, so
   `Task.async` and `Task.Supervisor` children are attributed to their page.
3. Otherwise return immediately. This fast path is the common case and must stay O(1).

**Sources** (verified against Phoenix 1.8 and LiveView 1.2.13 source; one
`:telemetry.attach_many/4` per plugin group, unique handler ids):

- `[:phoenix, :router_dispatch, :start | :stop | :exception]` (always emitted).
  `[:phoenix, :endpoint, :start | :stop]` comes from the host's `Plug.Telemetry` and is
  not guaranteed, so request timing is measured by our plug with a `before_send` callback.
- LiveView spans, all `:start | :stop | :exception`:

  | Event | Metadata | Notes |
  |---|---|---|
  | `[:phoenix, :live_view, :mount]` | `socket, params, session, uri` | runs twice: dead render (request process) and connected mount |
  | `[:phoenix, :live_view, :handle_params]` | `socket, params, uri` | |
  | `[:phoenix, :live_view, :handle_event]` | `socket, event, params` | |
  | `[:phoenix, :live_view, :render]` | `socket, force?, changed?` | also emitted per component with `component, id, cid`: tell them apart by `:component` |
  | `[:phoenix, :live_component, :handle_event]` | `socket, component, event, params` | `socket` is the component socket |
  | `[:phoenix, :live_component, :update]` | `socket, component, assigns_sockets` | `socket` is the parent LiveView socket |

  Plus `[:phoenix, :live_component, :destroyed]` (`socket, component, cid, live_view_socket`).
- **Assigns diff**: `socket.assigns.__changed__` is cleared right after render
  (`Utils.clear_changed/1` inside the render span), so the `:stop` socket of
  `mount`, `handle_params` and `handle_event` still carries it, while the render `:stop`
  socket does not. The diff is computed on callback `:stop` from the keys of
  `__changed__` (nil means everything changed).
- Ecto: `telemetry_prefix ++ [:query]` for each repo in `config :phoenix_dev_toolbar, repos: [...]`.
  Measurements: `query_time`, `decode_time`, `queue_time`, `idle_time`, `total_time` (native
  units, any may be missing). Metadata: `repo, query, params, cast_params, source, result,
  stacktrace` (`stacktrace` only with `stacktrace: true` in the repo config), `options`.
- Pull, not push: `Phoenix.LiveView.Debug.list_liveviews/0`, `socket/1` and
  `live_components/1` (the last two are `GenServer.call`s to the LiveView, so the panel
  calls them from its own process, never from a handler). Process metrics via
  `Process.info/2`. Both polled by the panel only while it is open.

**Built-in collectors** (default `plugins`, `PhoenixDevToolbar.Plugins.*`):

- `Request`: `router_dispatch` `:stop` and `:exception`: method, path, route pattern,
  handler (the LiveView module and action for live routes, else plug and options),
  status, redacted path params, duration; on exception also the error banner and the
  stacktrace without router and Plug frames.
- `Ecto`: `telemetry_prefix ++ [:query]` of each repo in `repos`, the prefix read from
  `repo.config/0` (a module that is not a repo is skipped with a warning). Records repo,
  SQL, redacted params (`cast_params` when present), source, result (`{:ok, rows}` or
  `{:error, message}`), the four timings in microseconds, the origin stacktrace without
  Ecto, DBConnection and repo frames, and `caller?` for queries from `$callers` children.

**Handler rules**: `PhoenixDevToolbar.Collector` attaches one handler per event name
(id `{PhoenixDevToolbar.Collector, event}`, an external function capture) that fans out
to the plugins declaring that event. The body is wrapped in `rescue` (a raising handler
is detached by `:telemetry`) and each plugin call in `catch`: a plugin that raises,
throws, exits or returns something other than `{:record, %Event{}}` or `:skip` is
quarantined (skipped until the next `attach/1`) and logged once. Only the plugin's
own call can quarantine it: Store and Notify failures are caught by the handler level
`catch` (every class, logged once per error type). No synchronous
GenServer calls, no I/O on the normal path; payloads are truncated before leaving the
plugin. Plugins come from `config :phoenix_dev_toolbar, plugins: [...]`; handlers are
attached when the application starts and detached in `prep_stop/1`.

## Consequences

- Untracked processes (background jobs, other users' pages) pay one `Process.get/1`.
- We rely on public telemetry contracts, so LiveView upgrades rarely break us.
- Reading `__changed__` and the `:"$phx_transport_pid"` pdict key relies on LiveView
  internals: both are isolated in `PhoenixDevToolbar.LiveViewCompat` and covered by the CI matrix.

## Open limits

- `handle_info/2` has no telemetry event: message tracing is an opt-in Phase 4
  feature based on `:erlang.trace/3` with rate limiting.
- Processes spawned without `$callers` (raw `spawn`, GenServers) are not attributed.
