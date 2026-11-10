# ADR 15: Loopback-only MCP Endpoint

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

**Who.** A request is answered only when, in this order:

- the Host cannot be rebound (`HostCheck`, as the panel), else 403;
- the peer is a loopback address and the request carries no proxy header
  (`x-forwarded-for`, `x-forwarded-host`, `x-forwarded-proto`, `x-real-ip`,
  `forwarded`), else 403;
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
| `page_summary` | `sid`, `path` | `Report.summary/2` plus `panel_url` |
| `page_queries` | `sid`, `path`, `limit` (1..200, 50), `sort` (`order`, `slowest`) | `sid`, `panel_url`, `total`, `returned`, `queries` |
| `page_callbacks` | as `page_queries` | `sid`, `panel_url`, `total`, `returned`, `callbacks` |
| `page_n_plus_one` | `sid`, `path` | `sid`, `panel_url`, `n_plus_one` |
| `page_errors` | `sid`, `path`, `limit` (1..100, 20) | `sid`, `panel_url`, `total`, `returned`, `errors` |

`panel_url` is absolute, built from the request's scheme, host and port
(`http://localhost:4000/__pdt/panel?sid=...`), so the agent can hand it to the
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
- It shows what the panel shows, to fewer clients (loopback only, no proxies).
  EXPLAIN, process actions and eval stay in the panel, behind their own policies.
- New MCP revisions may need a version added; an unknown one is refused with the
  supported list, so clients fall back.

## Open limits

- A dev server in a container, a VM, behind a proxy or bound to a Unix socket
  sees a non-loopback or proxied peer and refuses every request: there is no
  opt-in for it yet.
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
