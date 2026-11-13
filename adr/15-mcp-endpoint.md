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
  `Mcp-Method` and `Mcp-Name` headers must match the body (`Mcp-Name` may
  arrive as `=?base64?<b64>?=`, decoded before comparing; invalid base64 is a
  mismatch) (400 `-32020`
  otherwise); an unknown method gets 404 `-32601`. Results carry
  `resultType: "complete"`.

**Tools.** Read-only (`readOnlyHint: true`), over `Report` and the page
resolution of the standalone panel (ADR 14): a page is a `sid`, else the newest
page at an exact `path`, else the newest page. An explicit `sid` is used as
given, except a connected mount's sid, which reads as its request's page (`PageLookup.root/1`, so one page, one answer); `path` and
the default resolve to the request too. `list_pages` with both `path` and
`path_prefix` is an error.

| Tool | Arguments | Result |
|---|---|---|
| `list_pages` | `path`, `path_prefix`, `label` (exact actor label, ADR 13), `since` (a captured sid or ISO 8601 time: only later pages; a sid no longer in the Store is a tool error naming `started_at` as the fallback), `limit` (1..50, 10) | `pages`, newest first, each with `started_at` (ISO 8601), `label` (the actor, nil when none) and `panel_url`; a connected mount is part of its request's page, not a page of its own: a request row lists its connected LiveView sessions in `live_views` (`sid`, `view`, `path`, `label`, `started_at`, `events`; oldest first, at most 10, `live_views_more` counts the cut). Only the connected mounts the page tools read with the request sid are listed; a navigated LiveView (its parent is a LiveView) is its own row. One Store read serves all rows (`Report.sessions_in/2` over it) |
| `page_summary` | `sid`, `path`, `verbose` (boolean, false) | `Report.summary/2` (compact items unless `verbose`) plus `panel_url` |
| `page_queries` | `sid`, `path`, `limit` (1..200, 50), `sort` (`order`, `slowest`; checked, then ignored with `group_by`), filters `callback`, `event` (strings), `span`, `seq_from`, `seq_to` (non-negative integers), `verbose` (false), `group_by` (`caller`, `origin`, `callback`, `sql`; anything else is a tool error) | `sid`, `panel_url`, `total` (filtered rows), `returned`, `queries`; with `group_by`, `groups` instead of `queries` (`Report.query_groups/3`: `key` (for `callback`: owner, callback and event, ` (dead render)` for the request's own render, such as `DemoWeb.PageLive handle_event "save"`), `count`, `total_us`, `n_plus_one`, `sql`), `limit` and `total` counting groups, `queries_total` the queries grouped, noise left out. Compact rows by default: `seq`, `sid`, `span`, `callback`, `event`, `origin`, `caller`, `duration_us`, `rows`, `source`, `n_plus_one?`, `noise`, `error`, `sql` cut to 160 bytes on a UTF-8 boundary and `sql_truncated`; `verbose: true` returns the full rows (params, times, stacktrace, timestamp, whole SQL; ADR 13) |
| `page_callbacks` | `sid`, `path`, `limit`, `sort` as `page_queries`, filters `callback` and `event` (no compact mode) | `sid`, `panel_url`, `total`, `returned`, `callbacks`; inferred entries have `duration_us: null` (stated in the tool description) and `sort: "slowest"` puts every null duration last |
| `page_n_plus_one` | `sid`, `path` | `sid`, `panel_url`, `n_plus_one`, each group with `ran_in` and `callers` (ADR 13) |
| `page_errors` | `sid`, `path`, `limit` (1..100, 20) | `sid`, `panel_url`, `total`, `returned`, `errors` |
| `recent_errors` | `since` (a captured sid: errors after that page started, never its own sessions; or ISO 8601 time; same parsing and errors as `list_pages`), `limit` (1..100, 20) | `total`, `returned`, `errors` (`Report.recent_errors/1`, newest first), each with `page_sid` (the root: a connected mount reads as its request) and a `panel_url` to that page |
| `page_report` | `sid`, `path` | `sid`, `panel_url`, `markdown` (`Report.markdown/2`) as `structuredContent`; the text block is the Markdown itself, not JSON |
| `page_assigns_shape` | `sid`, `path` | `sid`, `view`, `live_view_sid` and `live_view_path` (the LiveView actually read: live navigation can make it a later one than the page's path), `panel_url`, `total_words`, `omitted`, `assigns` (at most 100, largest first, by `:erts_debug.flat_size/1` words of the untruncated value): `key` (inspect string), `type` (`list`, `map`, `struct Mod`, `binary`, ...), `length` (lists and maps), `words`, `stream?`. No values; each stream is its own entry, and a stream's words are what the server holds (its items live in the client). The LiveView is the page's newest one (a request page: its connected mount). Without `sid`, a newest capture whose LiveView is not alive (a dead render, a curl, a closed tab) yields to the newest page at the same path with a live LiveView, and `note` names both sids. `warning` when the LiveView read has another path than the page (live navigation). Tool errors: "the page has no LiveView" (a dead render only) is told apart from "the LiveView is gone" (tab closed or navigated away: open the page in a browser) |
| `compare_pages` | `before` (a captured sid, required), `after` (a captured sid) or `path` (the newest page at that path started after `before`; default: `before`'s path), not both | `Report.compare/3` (a connected mount reads as its request; `warning` when the sides differ in kind, session count or path), each side with its `panel_url` (`before.panel_url`, `after.panel_url`); no page after `before` is a tool error asking to reload the page, and an `after` older than `before` is a tool error |

`panel_url` is absolute, built from the request's scheme, host and port (the
port left out for 80 and 443): `http://localhost:4000/__pdt/panel?sid=...`, so the agent can hand it to the
developer. `path` and `path_prefix` are at most 2048 bytes.

Results come as `structuredContent` and as the same JSON in a text block, except
`page_report`, whose text block is its Markdown (ending in a footer with the sid and
the `panel_url`, also in `markdown`, so a 2025-03-26 client, which has no
`structuredContent`, and a pasted report keep the link). The footer is
`Report.markdown/2` with `panel_url:` (ADR 13): the panel's "Copy as Markdown"
passes an absolute link built from the panel request's base URL. Keys
and values follow `Report` (ADR 13) through one JSON normalizer: string keys,
modules and pids as `inspect/1` strings, timestamps in ISO 8601. Invalid
arguments and a missing page are tool errors (`isError: true`) whose text says
what to do: an argument error names the argument, what it takes, the JSON type it
got (never the value) and where to get a valid one (`before: a page sid string
(from list_pages or page_summary), got an object`, plus the `list_pages` call to
make when that object holds a `path`); an unknown argument lists the accepted
ones. An unknown tool is `-32602`. Input is never turned into atoms; a sid
must match `\A[A-Za-z0-9_-]{1,64}\z`.

**Prompts.** The `prompts` capability (`listChanged: false`) is advertised in
`initialize` and `server/discover`. `prompts/list` and `prompts/get` serve one
prompt, `audit_page(path)`: `path` is required, a non-empty string of at most
2048 bytes, only interpolated into the text. It returns one user message that
walks `page_summary`, `page_n_plus_one`, `page_queries` (slowest),
`page_errors` and, for a LiveView, `page_assigns_shape`, asks for findings with
the `panel_url`, and explains the check loop (`compare_pages`, `recent_errors`
with the sid). An unknown prompt or a bad `path` is `-32602`; on 2026-07-28
`prompts/get` also needs the `Mcp-Name` header to match `name`.

Tool names, arguments and result keys are a contract like `Report`'s: adding is
not a breaking change, renaming or removing is (a CHANGELOG line).

**Upgrades.** The server cannot push `notifications/tools/list_changed`: it has
no SSE stream, so `tools.listChanged` is `false`. A client keeps the tool list it
read at connect time, so after a `phoenix_dev_toolbar` upgrade new tools and
fields stay hidden until it reconnects (`/mcp` in Claude Code). `serverInfo.version`
in `initialize` (and `server/discover`) is the running release
(`Application.spec(:phoenix_dev_toolbar, :vsn)`); the README, the agent setup
guide, the usage rules and the shipped skill tell the user to reconnect after an
upgrade.

## Consequences

- Any MCP client measures a page before and after a change with one config line:
  no Tidewave, no remote shell, no browser automation.
- It shows what the panel shows, to fewer clients by default (this machine, no
  proxies); `clients:` opens it deliberately.
  EXPLAIN, process actions and eval stay in the panel, behind their own policies.
- New MCP revisions may need a version added; an unknown one is refused with the
  supported list, so clients fall back.

## Open limits

- `page_assigns_shape` reads the LiveView live (`Phoenix.LiveView.Debug.socket/1`, shared with the panel's Assigns snapshot, ADR 07): it needs the page open, copies the LiveView's assigns into a reader process (large assigns are briefly held twice) and is a tool error after 2 s (a busy LiveView). The reader is spawned and monitored, never linked to the request process (a host `max_heap_size` kill of the reader is a `gone` tool error, not a 500), and is killed at the timeout. Nested LiveViews and components are not covered; the reader, not the LiveView, does the size walk.
- `page_assigns_shape`: concurrent calls each copy the socket.
- `page_assigns_shape`: the 2 s timeout is soft (`flat_size` on a huge term does not yield).
- `page_assigns_shape`: `words` overstate data shared between assigns.
- `page_assigns_shape`: `live?` (is the owner alive) and the read are two steps: a tab closed between them is a `gone` tool error.
- `recent_errors` with a sid that expires between validation and read returns no errors instead of a tool error.
- `compare_pages` without `after` can pick a live navigation back to the same path (no reload) as the after page; `warning` flags a kind or session count mismatch, not that case.
- Behind a TLS-terminating proxy, `panel_url` and the Markdown footer use the transport scheme (`http`).
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
- No resources or change notifications.
- Clients connect when the agent starts: a dev server started later, or
  restarted, gives `ECONNREFUSED` until the client reconnects (`/mcp` in Claude
  Code). The README and `guides/agent-setup.md` say so, with the LAN address and
  `${PHX_IP:-127.0.0.1}` URL forms. The same applies to an address the server does not listen on
  (a `.mcp.json` URL with `${PHX_IP}` against a 127.0.0.1 bind). The first tracked
  request per boot logs one info line with the MCP URL the browser reached, plus
  a note when the endpoint's `http: [ip: ...]` is loopback (one
  `:persistent_term` read per request afterwards; nothing when `mcp: false`).
