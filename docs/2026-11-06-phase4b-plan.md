# Phase 4b plan: Process panel

Goal: a tab that answers "how is my LiveView process doing right now": memory and
how it grows, message queue, reductions, garbage collection, and the processes it is
linked to or monitors (its `Task.async` and `start_async` children included). It is
read while someone looks, and costs nothing otherwise.

Decisions go into a new ADR 09 (process panel) and ADR 05 (a new built-in in
`:defaults`). Socket RTT and `handle_info` tracing stay deferred.

## Where we start

- The page knows its LiveView process: `Page.owner` (ADR 04; it changes on every
  LiveView change, rejoins included). Nested LiveViews share the sid; their pids are in
  the pid index (`Store.pids_for/1`).
- The LiveView tab already polls while someone looks: `Panel.send_after/4`, started and
  stopped in `handle_props/1` from `@shown?` and `@visible?`, with reads that carry the
  owner they read so a late read of a previous LiveView is dropped
  (`panels/live_view.ex`, snapshot and tree).
- A plugin with no telemetry is allowed (`telemetry_events/1` may return `[]`), but no
  built-in does it yet.

## Design

**Plugin** `PhoenixDevToolbar.Plugins.Process` (`id: :process`, name "Process"), in
`:defaults` after LiveView. It attaches no telemetry (`collect/3` is never called) and
has no summary: it is a tab only.

**What it reads**, with `Process.info/2` and an explicit key list. It never reads
`:messages`, `:dictionary` or `:binary` whole, since each copies unbounded data.
- Every second while the tab is shown and the panel visible:
  - `memory`, `message_queue_len` and `reductions` (shown per second);
  - `total_heap_size`, `heap_size` and `stack_size`;
  - `garbage_collection` (`minor_gcs`, `fullsweep_after`, `min_heap_size`);
  - `status` and `current_function`.
- Once per page, and on demand: `initial_call`, the LiveView module,
  `registered_name` and `trap_exit`.
- **Relations**, every 5 seconds: `links`, `monitors` and `monitored_by`, at most 50 of
  each. Each related pid is shown with its registered name or its `$initial_call`, and
  marked as a `$callers` child when its `$callers` holds the LiveView. Those two are
  single dictionary keys, read with `Process.info(pid, {:dictionary, key})` (verify the
  OTP version that added it; fall back to `initial_call` and no marker before it). Ports
  are listed as ports.
- Samples: the last 60 values of memory, queue length and reductions per second, kept
  as fixed-size lists. That is a bounded assign, not a collection, so no stream is
  needed. They are drawn as inline SVG sparklines with the panel's tokens.

**Which process.**
- The page's `owner` by default.
- A selector lists the nested LiveViews of the page's sids (`Store.pids_for/1`), at most
  10, by module.
- The browser sends an index into that list, never a pid.
- A page without a LiveView (a dead page, or after the process exited) shows why, and
  polling stops.

**Polling** follows the LiveView tab:
- it starts in `handle_props/1` when `shown?` and `visible?`, and stops otherwise;
- it is reset when `page.owner` changes;
- a read result carries the pid it read, and a stale one is dropped;
- reads run in the component, because `Process.info/2` on a local pid is a BIF that
  never waits on the target. A dead pid returns nil, shown as "exited".

**Actions** (to decide): a "GC now" button, `:erlang.garbage_collect(pid)`, so a
developer can tell retained memory from garbage. It is the only thing the panel would do
to a host process.

## Tasks

Each task is one subagent slice, tests first, committed on its own, with one combined
reviewer, then the two final reviewers (technical and product) on the whole range.

1. **(R) Process reader** (pure-ish module, `PhoenixDevToolbar.ProcessInfo`).
   - It covers the key lists, bounded relations, `$callers` and `$initial_call`
     lookups, a dead pid, and reductions per second from two samples.
   - Verify `{:dictionary, key}` support on OTP 26 (our minimum) in the OTP sources or
     docs, and the fallback.
   - Tests: a spawned process with known links, monitors, a `Task.async` child, a big
     message queue (never copied: assert the reader does not read `:messages`), and a
     dead pid.
2. **Plugin and tab.**
   - Covers the plugin module, `:defaults` order, the `Panel` component with polling,
     samples, sparklines, the selector and the empty states, plus CSS.
   - Files: new `plugins/process.ex`, new `panels/process.ex`, `config.ex`,
     `components.ex` (sparkline), `panel.css`.
   - Tests:
     - end to end through `DemoWeb.Endpoint`: values show for the host LiveView;
     - polling only while shown and visible (as the tree tests do);
     - a nested LiveView selectable;
     - a tampered index is ignored;
     - after live navigation it reads the new owner.
3. **(R) Actions, if accepted.** GC now, rate limited (one per second), only on the
   selected page pid. Tests: memory reported before and after; a pid outside the page is
   never touched.
4. **Docs and harness.**
   - ADR 09 (new, index row), ADR 05 (defaults), README, CHANGELOG and roadmap ticks.
   - Harness: a `/memory` page that grows its assigns and its message queue on demand,
     to see the sparklines move.
   - Then `mix precommit`, the LiveView 1.1 run, the fixture builds, a browser check
     (light and dark, 800px, keyboard), and the two final reviews.

## Risks

- **Hot path:** none. No telemetry is attached; all the work runs in the panel's
  LiveView process, only while the tab is shown and visible.
- **Production footprint:** a new built-in plugin module, only referenced through
  `Config` when `enabled?/0`. No new dependency. `fixtures/host_app` compiles in prod.
- **Host impact:** `Process.info/2` on the host LiveView is cheap but not free; it
  runs once a second for scalars and once every 5 seconds for relations.
  - `:messages`, `:binary` and the whole `:dictionary` are never read: the first two
    copy unbounded data, the dictionary holds assigns-sized terms.
  - A GC on demand pauses the host process briefly: user triggered and rate limited.
- **Memory bounds:** 60 samples per series, at most 50 relations per kind and 10
  selectable LiveViews. No stream needed.
- **Security:** only pids derived from the page's sids are read; the browser sends an
  index.
- **Version compatibility:**
  - `Process.info/2` keys across OTP 26 to 29 (verify `{:dictionary, key}`).
  - `Page.owner` and the pid index are ours, so there is no LiveView internals
    involved.
- **Public API:** none new (an internal plugin). ADR 05 lists the new default.
- **Tests and ADR sync:** end to end through the endpoint against a real host
  LiveView process.

## Decisions

1. In `:defaults` (recommended), or opt-in?
2. "GC now" button: yes (recommended, rate limited), or read only?
3. Sampling: every second with 60 points, relations every 5 seconds (recommended)?
