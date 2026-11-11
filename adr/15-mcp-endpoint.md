# ADR 15: MCP Endpoint

**Status:** Implemented (2026-11-11)  
**Area:** integration  
**Related:** [ADR 13](./13-report-read-api.md) (the read API the tools serve), [ADR 14](./14-standalone-panel-and-row-attributes.md) (the same page resolution and `panel_url`), [ADR 04](./04-ui-delivery.md) (the plug's routes, the Host and Origin guards), [ADR 10](./10-process-addressing-and-actions.md) (what loopback means)

## Context

`PhoenixDevToolbar.Report` (ADR 13) answers "how many queries did `/posts` run"
only to code that runs inside the dev server's VM: IEx, a remote shell or
Tidewave's `project_eval`. Most coding agents have none of those, but all of
them speak MCP. An MCP server inside the toolbar gives them the same answers
with one line of client configuration.

## Decision

**Where.** `PhoenixDevToolbar.Plug` serves an MCP server at `<path>/mcp`
(`http://localhost:4000/__pdt/mcp` by default), on whenever the toolbar is on.
`config :phoenix_dev_toolbar, mcp: false` turns it off (404). No router, no new
dependency: JSON goes through `Phoenix.json_library/0`.

**Clients.** `mcp:` says which peers may call it:

- `true` (default), or `[clients: :local]`: this machine only, the same rule as
  `actions: :local` (ADR 10) and the Eval plugin's `clients: :local` (ADR 12). A loopback peer,
  or a peer whose address is one of this machine's own interface addresses
  (`:inet.getifaddrs/0`, read only for a peer that is neither loopback nor
  listed): a dev
  server bound to its LAN address, so phones can reach it, is called by an
  agent on the same laptop through that address. Another device cannot complete
  a TCP handshake with our own address, so this widens nothing beyond the machine.
- `[clients: ["192.168.1.0/24", "10.0.0.7", "fd00::/8"]]`: this machine plus
  these IPv4 and IPv6 addresses and CIDR ranges (an agent in a container or a
  VM, another device). An invalid entry logs one boot warning and is ignored.
- `[clients: :any]`: any peer, proxy headers included, with a boot warning:
  anyone who reaches the dev server can read the captured data.
- Any other value logs a boot warning and counts as `true`.

IPv4-mapped IPv6 peers compare as IPv4. Entries are parsed with
`:inet.parse_strict_address/1` and a prefix of 1 to 3 digits, never into atoms;
a malformed `mcp:` value or entry is warned at boot and never raises.

**Who.** A request is answered only when, in this order:

- the Host cannot be rebound (`HostCheck`, as the panel), else 403;
- the peer is allowed by `mcp:` (see Clients) and, unless `clients: :any`, the
  request carries no proxy header (`x-forwarded-for`, `x-forwarded-host`,
  `x-forwarded-proto`, `x-real-ip`, `forwarded`: the peer would be the proxy),
  else 403 with the peer address and the option that admits it (`clients: [...]`,
  or `clients: :any` for a proxied request), logged once per address (at most
  10 per boot);
- an `Origin`, when present, is the request's own origin or listed in
  `allowed_origins:`, else 403. CLI clients send none; a web page in the
  developer's browser sends its own, and a JSON `POST` from it needs a CORS
  preflight the toolbar never grants (CORS headers are stripped).

**Transport.** Streamable HTTP, stateless, JSON responses only: `POST` with
`application/json` (else 405 with `allow: POST`, or 415), a body of at most
1 MB (else 413). No SSE stream, no session id. A notification gets 202. Batches
get 400 `-32600`. The request is untracked: the endpoint's own reads are never
recorded. An unexpected exception becomes a 500 with `-32603`, logged once,
never a crash of the host's request process.

**Protocol versions.** Both eras on one endpoint:

- 2025-03-26, 2025-06-18, 2025-11-25: the `initialize` handshake. The server
  answers the client's version when supported, else 2025-11-25. An unsupported
  `MCP-Protocol-Version` header gets 400 `-32022`; a missing one counts as
  2025-03-26, which gets no `structuredContent`. An unknown method gets 200
  with `-32601`.
- 2026-07-28: a request whose `params._meta` names
  `io.modelcontextprotocol/protocolVersion` is served statelessly.
  `server/discover` lists the supported versions. The `MCP-Protocol-Version`,
  `Mcp-Method` and `Mcp-Name` headers must match the body (400 `-32020`
  otherwise); an unknown method gets 404 `-32601`. Results carry
  `resultType: "complete"`.

**Tools.** Read-only (`readOnlyHint: true`), over `Report` and the page
resolution of the standalone panel (ADR 14): a page is a `sid`, else the newest
page at an exact `path`, else the newest page. An explicit `sid` is used as
given (a connected mount's sid is not remapped to its request); only `path` and
the default resolve to the request. `list_pages` with both `path` and
`path_prefix` is an error.

| Tool | Arguments | Result |
|---|---|---|
| `list_pages` | `path`, `path_prefix`, `limit` (1..50, 10) | `pages`, newest first, each with `panel_url`; a connected mount is part of its request's page, not a page of its own |
| `page_summary` | `sid`, `path`, `verbose` (boolean, false) | `Report.summary/2` (compact items unless `verbose`) plus `panel_url` |
| `page_queries` | `sid`, `path`, `limit` (1..200, 50), `sort` (`order`, `slowest`) | `sid`, `panel_url`, `total`, `returned`, `queries` |
| `page_callbacks` | as `page_queries` | `sid`, `panel_url`, `total`, `returned`, `callbacks` |
| `page_n_plus_one` | `sid`, `path` | `sid`, `panel_url`, `n_plus_one` |
| `page_errors` | `sid`, `path`, `limit` (1..100, 20) | `sid`, `panel_url`, `total`, `returned`, `errors` |

`panel_url` is absolute, built from the request's scheme, host and port (the
port left out for 80 and 443): `http://localhost:4000/__pdt/panel?sid=...`, so the agent can hand it to the
developer. `path` and `path_prefix` are at most 2048 bytes.

Results come as `structuredContent` and as the same JSON in a text block. Keys
and values follow `Report` (ADR 13) through one JSON normalizer: string keys,
modules and pids as `inspect/1` strings, timestamps in ISO 8601. Invalid
arguments and a missing page are tool errors (`isError: true`) whose text says
what to do; an unknown tool is `-32602`. Input is never turned into atoms; a sid
must match `\A[A-Za-z0-9_-]{1,64}\z`.

Tool names, arguments and result keys are a contract like `Report`'s: adding is
not a breaking change, renaming or removing is (a CHANGELOG line).

## Consequences

- Any MCP client measures a page before and after a change with one config line:
  no Tidewave, no remote shell, no browser automation.
- It shows what the panel shows, to fewer clients by default (this machine, no
  proxies); `clients:` opens it deliberately.
  EXPLAIN, process actions and eval stay in the panel, behind their own policies.
- New MCP revisions may need a version added; an unknown one is refused with the
  supported list, so clients fall back.

## Open limits

- A dev server bound to a Unix socket has no peer address to match: only
  `clients: :any` lets its clients in.
- Anything on this machine that relays to the dev server counts as this machine,
  as it does for loopback: an SSH forward, socat, a local proxy without
  forwarded headers, a VM or container with user-mode NAT (VirtualBox NAT,
  QEMU slirp, podman pasta, host networking).
- A mapped IPv6 range (`::ffff:10.0.0.0/104`) is not accepted as an entry; use
  the IPv4 range. A zone suffix (`fe80::1%eth0`) is dropped.
- `panel_url` uses the host the agent called: from a container that is
  `host.docker.internal`, which the developer's browser may not resolve.
- A `path` with no capture is told apart from no capture at all, but `path` is an
  exact match: `/posts/` is not `/posts`, and a live patch keeps the mount path.
- Behind a proxy, only `clients: :any` works: the toolbar does not trust
  forwarded addresses.
- A client that disconnects while its body is read makes `Plug.Conn.read_body/2`
  raise in the request process, as the host's own `Plug.Parsers` would.
- An `initialize` asking for a version older than 2025-03-26 is answered
  2025-11-25 (the spec allows it; a strict old client may give up). A JSON-RPC
  response sent by the client gets 400: the server never sends requests.
- No authentication: any local process can read the captured data, as it can
  load the panel.
- Plugin events outside the built-ins, assigns snapshots and the component tree
  are not exposed (as in `Report`).
- No resources, prompts or change notifications.
- Clients connect when the agent starts: a dev server started later, or
  restarted, gives `ECONNREFUSED` until the client reconnects (`/mcp` in Claude
  Code). The README and `guides/agent-setup.md` say so, with the LAN address and
  `${PHX_IP:-127.0.0.1}` URL forms.
