# ADR 10: Process Addressing and Actions Policy

**Status:** Proposed  
**Area:** architecture  
**Related:** [ADR 09](./09-process-panel.md) (the Process tab, GC now), [ADR 11](./11-system-tab.md) (where any pid is inspected), [ADR 03](./03-event-storage.md) (bounds, no atoms from input)

## Context

ADR 09 reads only the page's processes, picked by index, and its only action is a
rate limited GC. Debugging a running system needs more: naming any process, moving
between processes, and acting on them (kill, suspend, watch). Each of these runs from
a browser over HTTP, against a node the developer is using, so a wrong click or a
reachable dev port must not freeze or kill the node.

## Decision

- **Addressing**: a process is named by a pid string (`"<0.123.0>"`, parsed with
  `:erlang.list_to_pid/1`, no atom created) or a registered name matched as a string
  against `Process.registered/0` (never `String.to_atom/1`). Local node only. The
  server re-validates every reference it gets from the browser. Page targets keep the
  ADR 09 index rule.
- **Navigation**: `Panel.navigate/3` (public) switches tab and hands the target panel
  `{:navigate, params}`; every pid the toolbar renders links to the inspector. The
  System tab (ADR 11) keeps a breadcrumb stack of at most 20 entries.
- **Protected set** (one module, unit tested): the toolbar's own processes (the
  `PhoenixDevToolbar.` name rule ADR 09 tags them with), the panel's pid and its
  socket transport, core registered names (`init`, `code_server`,
  `application_controller`, `logger`, ...), any process of the `kernel`, `stdlib`,
  `elixir`, `logger` or `compiler` applications, and the host endpoint's supervisor.
  Reads and GC are allowed on them; kill and suspend are refused.
- **Actions**, each behind a confirm step, rate limited and logged with `Logger`:
  - Kill: the page's LiveView with a chosen reason (`:kill`, `:shutdown`,
    `{:shutdown, :debug}`, a raise), or any non protected pid.
  - Suspend: always with a TTL (default 10s, at most 60s). Resume is owned by a
    supervised toolbar process that monitors the panel, so a closed panel never leaves
    a suspended process.
  - Watch: the panel monitors up to 10 pids and shows exit reason and time.
  - Message peek: the first messages only while `message_queue_len` is under a
    threshold (100); `:messages` is never read above it.
- **Who may act**: reads and GC are open to any panel. Kill, suspend and message peek
  follow the top level `actions:` config: `:loopback` (default, the panel socket's
  peer must be a loopback address), `:any` (warned at boot), `false` (no actions).
  Docker and LAN setups need `actions: :any`; the panel says so when it refuses.
- **Not offered**: link/unlink (only creates cascading crashes), sending arbitrary
  messages (needs term parsing: that is eval, ADR 12), forced hibernate.

## Consequences

- The toolbar can now harm a host process on purpose: every destructive path is
  confirmed, rate limited, and refused on the protected set.
- `Panel.navigate/3` is new public API for plugin authors.

## Open limits

- A client behind a local reverse proxy reads as loopback.
- A process suspended while it holds a lock others wait on stalls them until the TTL.
