# ADR 12: Cluster and Eval Plugins

**Status:** Implemented (2026-11-09)  
**Area:** plugins  
**Related:** [ADR 05](./05-plugin-behaviour.md) (plugins), [ADR 10](./10-process-addressing-and-actions.md) (actions policy), [ADR 01](./01-zero-prod-footprint-and-installation.md) (dev only)

## Context

Distributed dev setups (several nodes, `libcluster`) raise questions the toolbar
cannot answer today: which nodes are connected, how loaded they are. Running code
against the node from the panel is the next step, and the most dangerous one: a
panel served over HTTP that evaluates code is remote code execution for anyone who
reaches the dev port (Docker and LAN setups often bind `0.0.0.0`).

## Decision

Two built-in plugins shipped in this library, **neither in `:defaults`**: a host
adds them to `plugins:`. Both are tabs only (no telemetry), and their reads run in
the panel's `start_async/3` tasks, never in the panel process.

- `PhoenixDevToolbar.Plugins.Cluster` (`:cluster`, "Cluster"): this node (and
  whether it is distributed at all) and up to 50 connected nodes, visible or
  hidden, each read in its own task with a 1 s deadline through `:erpc` calls of
  stdlib functions only (the other node may not have this library): round trip
  time, process count, total memory, OTP release, uptime. A node that does not
  answer in time says so. Read while the tab is shown and the panel visible, every
  `refresh_ms` (5000, 1000 to 60000), and on Refresh.
- `PhoenixDevToolbar.Plugins.Eval` (`:eval`, "Eval"), safe defaults, each
  overridable, and `allow: :eval` warned about when the plugin is attached (with
  who may then run code):
  - `allow: :read_only` (default): a fixed list of read queries (memory, system
    and build info, run queues, started applications, the largest ETS tables,
    process, port, ETS and atom counts, registered names), picked by id from a
    select, never by code. `allow: :eval` adds an editor: code typed in the panel
    is evaluated on the node.
  - `clients: :loopback` (default): code runs only when the panel's websocket
    peer is a loopback address, not reached through a proxy (the same client
    `actions:` uses, ADR 10), checked on every event as well as in the page.
    `clients: :any` lifts it. The read queries answer any browser: they show what
    the System tab's reads show (ADR 10: process info reads are open). The panel's host guard (ADR 04) keeps a
    rebound attacker domain out. The off message suggests an SSH tunnel to
    localhost rather than `clients: :any`.
  - `timeout_ms:` (5000, 100 to 60000): code runs in a process of its own, killed
    by a watchdog process when it outlives it (even if the panel that asked is gone). Its
    group leader keeps the first 8 KB of what it prints and drops the rest while it
    runs. The result is inspected and truncated, an exception formatted; each run
    is logged with its size, never its code; the last 10 runs are kept. The editor
    and its result answer only clients that pass the check above, on every event.
  - No per boot token: the panel is already reachable only through its signed
    session and the endpoint's `check_origin` (ADR 04), and a token shown in the
    same page would add nothing against whoever can open it.
- Security notes live here, in the plugin's moduledoc and in `SECURITY.md`.

## Consequences

- With overrides on, anyone reaching the dev server can run code as the BEAM user.
- Eval makes "send a message" and other free form actions possible without adding
  them to ADR 10.
- Evaluated code is the developer's: it may create atoms, spawn processes the
  timeout does not stop, run commands, or halt the node. Compiler diagnostics go
  to the host's stderr.
- `actions: false` does not turn Eval off: Eval has its own options and is
  installed on purpose.

## Open limits

- Loopback checks behind a local reverse proxy see the proxy's address.
- Remote processes are not inspectable from the System tab yet (local only).
- The Cluster tab is not tested against a second node (the test VM is not
  distributed).
