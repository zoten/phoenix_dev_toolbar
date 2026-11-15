# ADR 17: MCP stdio Wrapper

**Status:** Proposed  
**Area:** integration  
**Related:** [ADR 15](./15-mcp-endpoint.md) (the HTTP endpoint it forwards to), [ADR 01](./01-zero-prod-footprint-and-installation.md) (what the dep may add to a host app), [ADR 13](./13-report-read-api.md) (the read API behind the tools)

## Context

MCP clients connect to an HTTP server once, when the agent starts. If the dev
server is not up yet, restarts, or listens on another address than the
configured URL, every tool call fails with a bare `ECONNREFUSED` until the user
reconnects by hand (ADR 15, Open limits). Agents that measure pages in long
sessions hit this often and fall back to their own scripts. The boot log line
with the MCP URL helps a human, not the agent.

An MCP client also supports stdio servers: it starts a command and talks
JSON-RPC over its stdin and stdout. That process lives as long as the agent, so
it can reach the dev server whenever it is up and say clearly when it is not.

## Decision

**Entry point.** `mix pdt.mcp`, a Mix task in `lib/` (`Mix.Tasks.Pdt.Mcp`), run
in the host project. The dep is `only: :dev`, so the task does not exist in a
prod build; the `pdt.` prefix avoids clashes with the host's tasks. Client
configuration: `{"command": "mix", "args": ["pdt.mcp"]}`.

**Behaviour.** A stdio JSON-RPC loop that serves what it can locally and
forwards the rest:

- `initialize`, `ping`, `tools/list`, `prompts/list` and `prompts/get` are
  answered locally from `PhoenixDevToolbar.MCP.Protocol` (the task runs with the
  host's compiled deps, so the tool list matches the installed version). The
  client connects even with no dev server running.
- `tools/call` is forwarded to the HTTP endpoint with `:httpc` (OTP `inets`,
  started by the task: no new dependency), one request per call, so a server
  started or restarted later is picked up with no reconnect.
- A refused or timed-out connection is a tool error (`isError: true`), not a
  JSON-RPC error: "no dev server at http://127.0.0.1:4000/__pdt/mcp (tried:
  ...). Start it with `mix phx.server` or `iex -S mix phx.server`, then call
  again." A 403 forwards the endpoint's own message (which names the `mcp:`
  option to change).

**Finding the server.** In order: `--url`, then `PDT_MCP_URL`, then
`http://127.0.0.1:<port>/__pdt/mcp` with the port from `PORT`, else the host
endpoint's dev `http: [port: ...]` config, else 4000. The toolbar `path:` comes
from its config. On a refused connection to `127.0.0.1` the task also tries
`localhost` (IPv6) and the endpoint's configured `ip`, and remembers the one
that answers.

**Stdout is the protocol.** Nothing else may write to stdout: the task moves the
Logger console backend and `Mix.shell` output to stderr before the first read.
Compilation must not print to stdout: see Open limits.

## Consequences

- The agent stays connected across server restarts and can tell "server down"
  from "toolbar off" from "not allowed", with the fix in the message.
- One more public surface (the task name, its flags and env var) to keep stable.
- The HTTP endpoint stays the source of truth: the wrapper adds no tools and
  reads no captured data itself, so the access rules of ADR 15 still apply.
- Subagents still need their own MCP connection; the `curl` recipe (ADR 15
  docs) covers them.

## Open limits

- Mix may compile the host or its deps before the task runs, printing to
  stdout and breaking the handshake. To check: whether `MIX_QUIET`,
  `@requirements []` and running before `compile` are enough, or the docs must
  say "compile once before starting the agent".
- Reading the endpoint's port needs the host config loaded (`app.config`), which
  runs `config/runtime.exs`: a runtime config with side effects runs them.
  Alternative: `PORT` and `--url` only.
- Startup cost: a `mix` boot per agent session (about a second).
- A server on another machine or in a container needs `--url`, as the HTTP
  client config does today.
