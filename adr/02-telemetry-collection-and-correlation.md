# ADR 02: Telemetry Collection and Correlation

**Status:** Accepted  
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
- Live navigation starts a new LiveView process with a new `socket.id` and no HTTP
  request. Its session gets a new sid with `parent` set to the previous sid of the same
  `socket.transport_pid` (one transport per browser tab, also stored by LiveView in the
  `:"$phx_transport_pid"` pdict key). The panel follows the tab: it shows the newest sid
  of its transport.
- Nested LiveViews (`live_render`) run in their own process: they inherit the sid of
  `socket.parent_pid` / `socket.root_pid`.

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

**Handler rules**: the body is wrapped in `try/rescue` (a raising handler is detached
by `:telemetry`); errors are logged once per handler; no synchronous GenServer calls,
no I/O; payloads are truncated before leaving the handler.

## Consequences

- Untracked processes (background jobs, other users' pages) pay one `Process.get/1`.
- We rely on public telemetry contracts, so LiveView upgrades rarely break us.
- Reading `__changed__` and the `:"$phx_transport_pid"` pdict key relies on LiveView
  internals: both are isolated in `PhoenixDevToolbar.LiveViewCompat` and covered by the CI matrix.

## Open limits

- `handle_info/2` has no telemetry event: message tracing is an opt-in Phase 4
  feature based on `:erlang.trace/3` with rate limiting.
- Processes spawned without `$callers` (raw `spawn`, GenServers) are not attributed.
