# ADR 07: LiveView Panel: Profiler, Assigns, Event Log, Component Tree

**Status:** Implemented (2026-11-05)  
**Area:** ui  
**Related:** [ADR 02](./02-telemetry-collection-and-correlation.md) (the `:live_view` events), [ADR 03](./03-event-storage.md) (bounds), [ADR 04](./04-ui-delivery.md) (panel, loader, bridge)

## Context

The LiveView tab shows, for the page's LiveView, where time goes, what the
assigns hold and how they change, what happened on the server and in the
browser, and which components are rendered. Some of it comes from telemetry
(push, recorded in host processes), some only from the LiveView process itself
(pull, through `Phoenix.LiveView.Debug`), and some only from the browser.
Pulling means calling into a host process; listening in the browser means
running code in the host page. Both must stay cheap and read only.

## Decision

One `LiveView` tab, the `PhoenixDevToolbar.Plugins.LiveView` plugin's panel component
(`PhoenixDevToolbar.Panels.LiveView`, on the public plugin API, ADR 05; its markup in
`Panels.LiveViewSections`) with four WAI-ARIA sub-tabs: Profiler, Assigns, Events,
Components. Its state (profile, reads, timers, client events) lives in the component.
Like the other tabs it shows the page (`PhoenixDevToolbar.Page`) and follows live
navigation.

- **Profiler**: `PhoenixDevToolbar.Profile` folds `:live_view` events in the panel
  process into one row per `{callback, subject, event}` (subject: the component or
  nested LiveView module, nil for the page's LiveView; renders are
  `{:render, component, nil}`): count, total, average, max. At most 100 rows, then
  one `other` row, since event names come from the client. The fold survives the
  Store trimming old events; it restarts with the page. The summary bar shows the
  callback count and the slowest callback.
- **Events**: a stream (500 rows) of `:callback` and `:render` events (changed keys,
  redacted values and params, pushed event names, errors, `HTTP`/`live` phase) and
  client events, in arrival order. Reset on live navigation.
- **Assigns**: a snapshot of the page's newest LiveView: `Debug.socket/1` runs in a
  `start_async/3` task that also truncates (`Truncate.snapshot/1`: 100 assigns,
  sorted, each through `Truncate.preview/3`, sensitive keys redacted), so the whole
  socket never reaches the panel's assigns. Read when the sub-tab opens, on Refresh,
  and after new callbacks at most once per second while the panel is open and
  visible (a throttled refresh is scheduled, so the last callback is never missed).
  Keys changed by the last callback are highlighted. A dead page shows "No LiveView
  on this page", a dead owner "not running anymore". The read itself is one
  internal function, `LiveViewAssigns.fetch/1` (and `owner/1` for the page's newest
  LiveView), shared with MCP `page_assigns_shape` (ADR 15).
- **Components**: `PhoenixDevToolbar.ComponentTree` reads, in a task, the page's
  LiveView and its nested LiveViews (the processes tracked as the page,
  `Store.pids_for/1`, labelled through `LiveViewCompat.live_view_label/1`), and for
  each `Debug.live_components/1`, keeping only module, id and cid nested by
  `children_cids`: 500 nodes at most for the page. Read when the sub-tab opens, then
  polled every 2 s only while the sub-tab is shown and the panel is open and
  visible. Nested LiveViews are listed under the page's LiveView.
- **Timers**: the throttled snapshot and the tree poll are `Panel.send_after/4`
  messages (`send_update_after`) to the component.
- **Reads and page changes**: one snapshot and one tree read at a time; each read
  returns the owner it read, and a result for another owner than the page's current
  one is dropped (a read that finished just before a page change). When the
  page's LiveView changes (connected, navigated, rejoined) reads in flight are
  cancelled (`cancel_async/3`) and restarted for the new LiveView, so a result
  never lands on the wrong page.
- **Visibility bridge**: a `PdtPanel` hook (registered in our own `LiveSocket`, on an
  empty `#pdt-bridge` element) pushes `pdt:visibility` (`open` from the loader's
  `pdt:state`, `document.visibilityState`) on join, reconnect and change. A hook
  push locks its element until the reply: on the panel root, a diff landing in the
  locked tree lost its stream resets (live navigation kept the old rows), hence the
  dedicated element. Pushes use the callback form, which drops pushes while
  disconnected instead of rejecting.
- **Client events**: the loader listens, passively, to LiveView's window events
  `phx:page-loading-start`, `phx:page-loading-stop` and `phx:navigate` (a fixed
  list: there is no wildcard listener, so `push_event` names are logged server side
  instead, ADR 02). It copies only own data properties `kind`, `to`, `href`,
  `patch`, `pop` holding scalars (strings capped at 256 characters; accessor getters
  never run, and a throwing Proxy trap is caught: the listener never throws into the
  host's dispatch or error tracking), stamps `Date.now()`, allows 20 per second, buffers 50 until the panel
  loads, and posts `pdt:client` through the origin and source checked bridge, with
  the number of dropped events (also reported alone a second after a burst).
  `panel.js` forwards to the hook (50 buffered until join); `PanelLive` forwards them
  to the LiveView tab's component, which accepts, through
  `PhoenixDevToolbar.ClientEvent`, only those types and fields, caps strings again
  and streams them. Nothing is stored in
  ETS. The client events that announce a live navigation arrive just before it
  resets the log: the last 10 received in the previous 2 s are shown again after the
  reset. The pure helpers (`assets/js/client_events.mjs`) have Node unit tests
  (`mix test.js`).

- **Crashes**: a callback or render that raises stores its banner (`error`) and
  its `stacktrace`: formatted frames without the toolbar's and `:telemetry`'s,
  in call order, cut after the last host frame plus the one after it, at most 10.
  A frame is a host frame when its module's source file (`module_info(:compile)`)
  lies under a host source root, so modules created and code-reloaded during the
  session count. The roots (the Mix project directory, an umbrella's app
  directories, never the deps path; from an umbrella child's directory only that
  child counts) are resolved once at `Collector.attach/1` into a `:persistent_term`,
  never in a handler. `origin` is the first host frame. When the roots are unknown
  (no Mix) or no host frame is present, the first 10 frames are kept and `origin`
  is the first frame. Successes store `[]`. With the opt-in `stack_args:` the
  frames that carried call arguments also store them as `stack_args`
  ([ADR 03](./03-event-storage.md)); the panel shows them, `Report` only with
  `agents: true`.

## Consequences

- The host pays for pulls only while someone looks: `Debug.socket/1` copies the
  socket inside the host LiveView at most once per second, `Debug.live_components/1`
  every 2 s, and both are `GenServer.call`s with a 5 s timeout that block our task,
  never the panel process.
- Panel memory is bounded: folds, a 100 key snapshot, a 500 node tree, 500 row
  streams.
- Client events cover LiveView navigation; custom `phx:*` events from
  `push_event` show as names on the server callback that pushed them.

## Open limits

- `Debug.live_components/1` copies every component's full assigns into our task
  every poll, and `live_view_label/1` copies the host process dictionary: only
  while the Components sub-tab is shown and visible.
- Component ids and exception banners are bounded but not redacted: an id built
  from an email shows the email.
- Nested LiveViews are shown one level deep under the page's LiveView; deeper
  nesting is flattened.
- The snapshot is the page's main LiveView only, not nested LiveViews or
  components.
- Client events pushed while the panel socket is disconnected, or posted while the
  iframe reloads, are lost without being counted as dropped.
- Client timestamps come from the browser clock; they are kept but not used for
  ordering (rows are in arrival order).
- The dead render shows empty sub-tabs ("No LiveView callbacks yet"): the plugin's
  events reach the component once the panel connects.
- Without `Plugins.LiveView` (`{:exclude, ...}`) there is no LiveView tab and client
  events are dropped.
