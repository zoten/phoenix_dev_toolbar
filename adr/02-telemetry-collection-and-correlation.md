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
- For LiveView, a `[:phoenix, :live_view, :mount, :start]` handler tracks the LiveView
  process: the sid is derived from the root LiveView `socket.id`, which the loader also
  reads from the `[data-phx-main]` element and sends to the panel. The panel links the
  dead render sid and the LiveView sid into one page view.

**Attribution** (inside the handler, in this order):

1. `Process.get(:pdt_sid)`: tracked request or LiveView process.
2. `Process.get(:"$callers")`: look up the callers in a `pid -> sid` ETS index, so
   `Task.async` and `Task.Supervisor` children are attributed to their page.
3. Otherwise return immediately. This fast path is the common case and must stay O(1).

**Sources** (one `:telemetry.attach_many/4` per plugin group, unique handler ids):

- `[:phoenix, :endpoint, :start | :stop]`, `[:phoenix, :router_dispatch, :start | :stop | :exception]`
- `[:phoenix, :live_view, :mount | :handle_params | :handle_event | :render, :start | :stop | :exception]`
- `[:phoenix, :live_component, :handle_event | :update, :start | :stop | :exception]`
- Ecto: `telemetry_prefix ++ [:query]` for each repo in `config :phoenix_dev_toolbar, repos: [...]`
- Pull, not push: component tree and socket via `Phoenix.LiveView.Debug`, process
  metrics via `Process.info/2`, both polled by the panel only while it is open.

**Handler rules**: the body is wrapped in `try/rescue` (a raising handler is detached
by `:telemetry`); errors are logged once per handler; no synchronous GenServer calls,
no I/O; payloads are truncated before leaving the handler.

## Consequences

- Untracked processes (background jobs, other users' pages) pay one `Process.get/1`.
- We rely on public telemetry contracts, so LiveView upgrades rarely break us.

## Open limits

- Phase 0 spike must confirm against LiveView 1.1 source: exact event names and
  metadata (notably `live_component` `update`), whether `socket.assigns.__changed__`
  is still populated in `:stop` metadata, and the `Phoenix.LiveView.Debug` API.
- `handle_info/2` has no telemetry event: message tracing is an opt-in Phase 4
  feature based on `:erlang.trace/3` with rate limiting.
- Processes spawned without `$callers` (raw `spawn`, GenServers) are not attributed.
