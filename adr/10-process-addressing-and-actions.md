# ADR 10: Process Addressing and Actions Policy

**Status:** Implemented (2026-11-09)  
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
  `elixir`, `logger` or `compiler` applications, application masters, and the host
  endpoint's supervisor.
  Reads and GC are allowed on them; kill and suspend are refused.
- **Actions** (`ProcessActions`; the System tab offers all of them, the Process tab
  Kill for its LiveView, which then reconnects and remounts). Kill and suspend wait
  for a confirm click, run at most once a second per tab and are logged with
  `Logger.warning/1`. The toolbar hands every tab an internal `pdt_actions` assign
  (the client's address, the panel's pid, its transport and the endpoint) for
  these checks:
  - Kill, with a reason picked from a fixed list: `kill` (`:kill`, untrappable),
    `shutdown`, or `crash` (an exit with a `RuntimeError`, as a crash looks to logs
    and supervisors). A suspended process can still be killed.
  - Suspend for 10 s (`Suspender`, a toolbar child only when enabled, accepts 1 to
    60 s and at most 10 processes). It resumes on the TTL, when the panel that asked
    goes away, or on Resume; a process it suspended is released by OTP if the
    Suspender itself dies. GC now and the state read refuse a suspended process
    (both would wait for it).
  - Watch: the System tab monitors up to 10 processes and lists each one's exit
    reason and time. Its monitors are routed: the panel process receives the `DOWN`
    and hands it to the tab that set the monitor only, never to plugin tabs. A
    watch whose `DOWN` was dropped while the tab was disabled is marked on Re-enable.
  - Message peek: the first 10 messages, each redacted and truncated, only while
    `message_queue_len` is under 100; `:messages` is never read above it.
- **Who may act**: reads, GC and Watch are open to any panel. Kill, suspend and message peek
  follow the top level `actions:` config: `:loopback` (default, the panel socket's
  peer must be a loopback address), `:any` (warned at boot), `false` (no actions).
  Docker and LAN setups need `actions: :any`; the panel says so in place of the
  actions when it refuses, as it says why a protected process offers none.
- **Not offered**: link/unlink (only creates cascading crashes), sending arbitrary
  messages (needs term parsing: that is eval, ADR 12), forced hibernate.

## Consequences

- The toolbar can now harm a host process on purpose: every destructive path is
  confirmed, rate limited, and refused on the protected set.
- `Panel.navigate/3` is new public API for plugin authors.

## Open limits

- A client behind a local reverse proxy, or Docker's userland port proxy, reads as
  loopback: loopback then means "whoever reaches the proxy".
- The endpoint's children (listener, acceptors, connection supervisors) and the
  host Repo pool are not protected: their supervisors restart them, but killing a
  connection supervisor drops the panel's own websocket until it reconnects.
- A process suspended while it holds a lock, a checked out Repo connection or a
  `:global` transaction stalls whoever waits on it until the TTL.
- Message peek reads the queue length, then the queue: a process flooded between
  the two reads is copied whole into the panel once.
- Redaction walks tuples of up to 50 elements: a secret in a bigger tuple (a large
  record) is shown, truncated.
