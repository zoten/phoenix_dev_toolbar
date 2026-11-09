# ADR 12: Cluster and Eval Plugins

**Status:** Proposed  
**Area:** plugins  
**Related:** [ADR 05](./05-plugin-behaviour.md) (plugins), [ADR 10](./10-process-addressing-and-actions.md) (actions policy), [ADR 01](./01-zero-prod-footprint-and-installation.md) (dev only)

## Context

Distributed dev setups (several nodes, `libcluster`) raise questions the toolbar
cannot answer today: which nodes are connected, how loaded they are. Running code
against the node from the panel is the next step, and the most dangerous one: a
panel served over HTTP that evaluates code is remote code execution for anyone who
reaches the dev port (Docker and LAN setups often bind `0.0.0.0`).

## Decision

Two built-in plugins shipped in this repo, **neither in `:defaults`**.

- `PhoenixDevToolbar.Plugins.Cluster`: connected nodes (`Node.list/0`), connection
  state, per node memory and process count over `:erpc` with timeouts. Remote pids
  become inspectable read-only through `:erpc`.
- `PhoenixDevToolbar.Plugins.Eval`, safe defaults, each overridable:
  - `allow: :read_only` (default): a curated list of read calls, no free text eval.
    `allow: :eval` enables evaluation of typed code.
  - `clients: :loopback` (default): refused unless the client address is loopback,
    checked on the HTTP request and the panel socket, plus a per boot token.
    `clients: :any` lifts it.
  - Every override logs a warning at boot. Code runs in a supervised task with a
    timeout; output is truncated.
- Security notes live in this ADR, the plugin guide and `SECURITY.md`.

## Consequences

- With overrides on, anyone reaching the dev server can run code as the BEAM user.
- Eval makes "send a message" and other free form actions possible without adding
  them to ADR 10.

## Open limits

- Loopback checks behind a local reverse proxy see the proxy's address.
