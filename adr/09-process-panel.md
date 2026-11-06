# ADR 09: Process Panel

**Status:** Implemented (2026-11-06)  
**Area:** ui  
**Related:** [ADR 04](./04-ui-delivery.md) (the page and its owner), [ADR 05](./05-plugin-behaviour.md) (a built-in plugin), [ADR 07](./07-live-view-panel.md) (the same "only while someone looks" polling)

## Context

A LiveView is a long lived process. When a page gets slow or heavy, the questions
are about that process: how much memory it holds and whether it grows, whether its
message queue backs up, how busy it is, what it is linked to, which tasks it started.
The BEAM answers all of them through `Process.info/2`, but nobody opens a remote
shell to ask while clicking through a page.

## Decision

A built-in plugin, `PhoenixDevToolbar.Plugins.Process` (`:process`, tab "Process"),
in `:defaults` after LiveView. It attaches no telemetry and has no summary: a tab
only, reading the page's process while the tab is shown and the panel visible.

- **Which process**: the page's LiveView (`Page.owner` through its session), then
  the other processes of the page's sids (nested LiveViews share their parent's sid,
  `Store.pids_for/1`), at most 10. The browser picks one by its index in that list,
  never by pid. A page without a LiveView says so.
- **What is read** (`PhoenixDevToolbar.ProcessInfo`, explicit `Process.info/2` key
  lists): every `sample_ms`, memory, message queue length, reductions (shown per
  second), heap, total heap and stack sizes, garbage collection counters, status and
  current function; every `relations_ms`, links, monitors and monitors on it, 50 of
  each (the rest counted), each related process named (registered name, its
  `$initial_call`, a supervisor's module, or what it runs now) and marked as a child
  when its `$callers` holds the LiveView; once per target, how it started and whether
  it traps exits. It never reads `:messages`, `:binary` or the whole `:dictionary`
  (unbounded copies); two dictionary keys are read one at a time
  (`{:dictionary, key}`, OTP 26.2+, checked once; older OTPs skip them). Remote pids
  and ports are named by their node and never read.
- **Sparklines**: memory, queue and reductions per second keep the last `samples`
  points, inline SVG with the panel's tokens.
- **Polling**: `Panel.send_after/4` timers, started from `handle_props/1` when the tab
  is shown and the panel visible, renewed only while that holds. Each timer carries a
  token, and scheduling replaces the pending timer of its kind: a tick that is not the
  pending one is dropped, so there is one loop per kind whatever raced. The target list
  is refreshed on every relations tick (a nested LiveView mounts after its parent, in
  the same sid, so the page does not change); exited pids are skipped and a target that
  left the list gives way to the first. A dead target stops the loop.
- **GC now**: the only thing the panel does to a host process. A button runs
  `:erlang.garbage_collect/1` on the selected process, in `start_async/3` (a target busy
  in a long NIF never blocks the panel), at most once a second, and shows the memory
  before and after: what is left is memory the process really holds.
- **Options** (`{PhoenixDevToolbar.Plugins.Process, ...}`, validated in `init/1`, an
  unknown one refused): `sample_ms:` (1000, 250 to 60000), `samples:` (60, 2 to 600),
  `relations_ms:` (5000, 1000 to 300000).

## Consequences

- One more default tab for every host: until it is opened it only reads the Store
  (which processes the page has), never the host process.
- A full sweep GC pauses the host process for as long as it takes: user triggered and
  rate limited.
- A read is a signal the target answers: a host process stuck in a long NIF delays
  the panel, never the reverse.
- Links and monitors are copied whole by `Process.info/2` before being cut to 50: a
  process with tens of thousands of them costs a few milliseconds per relations poll.

## Open limits

- Nested LiveViews are labelled "nested LiveView": their sessions are their parent's.
- Plain `Task.async` children run the function they were given: their name is that
  function; `start_async` tasks all read as LiveView's async runner.
- No summary badge (no events): a growing queue only shows in the tab.
