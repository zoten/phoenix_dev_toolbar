# ADR 00: Vision and Scope

**Status:** Accepted  
**Area:** product  
**Related:** [ADR 01](./01-zero-prod-footprint-and-installation.md) (install and prod rules), [ADR 05](./05-plugin-behaviour.md) (extensibility)

## Context

Developers building Phoenix LiveView apps inspect queries, assigns and process
health through `IO.inspect`, logs or a separate dashboard (`Phoenix.LiveDashboard`).
None of these show "what happened for the page I am looking at, right now".
`django-debug-toolbar` solves this for request/response apps; LiveView adds a
long-lived stateful process per page, which changes how data must be collected
and bounded.

## Decision

`phoenix_dev_toolbar` is a dev-only overlay that shows, for the current page
(dead render + its LiveView process), live data in panels:

- **LiveView and components**: component tree (router, root LiveView, nested
  LiveViews, LiveComponents), assigns inspector with per-event diff, lifecycle
  profiler (`mount/3`, `handle_params/3`, `handle_event/3`, `render/1`,
  component `update/2`), event log (server callbacks and client `phx:*` events)
- **Ecto**: queries executed by the request or LiveView (and its `Task` children),
  with total/queue/query/decode times, source, stacktrace origin, N+1 detection
  and an `EXPLAIN` action
- **BEAM**: LiveView process memory, message queue length, GC stats, reductions,
  linked/monitored processes. Beyond the page, the
  System tab inspects, walks (links, ancestors, supervision and application trees)
  and acts on (kill, suspend, watch) any local process: the debugging a developer
  would otherwise do from a remote shell or observer, next to the page that
  prompted it (ADR 10, ADR 11)
- **Extensibility**: every panel, including built-ins, is a `PhoenixDevToolbar.Plugin`

Non-goals: production monitoring, metrics over time and historical storage across
restarts (that is LiveDashboard's job), non-Phoenix Plug apps, a client to server socket
RTT readout (not planned). Cluster views are left to opt-in plugins (ADR 12).

Supported versions: Elixir 1.17+, Phoenix 1.8+, LiveView 1.1+. License: MIT.

## Consequences

- Built-in tabs: Request, Ecto, LiveView, Process and System are on by default. System
  actions (kill, suspend, message peek, trace), Cluster and Eval are opt-in. Each is a
  plugin, so the surface stays bounded by the plugin API. The library can lean on LiveView 1.1 primitives
  (`Phoenix.LiveView.Debug`, colocated hooks) instead of private internals.
- Supporting older LiveView versions is out of scope until users ask.

## Open limits

- Multi-node apps: data is only collected on the node serving the page.
- Dead views without LiveView show request and Ecto panels only.
