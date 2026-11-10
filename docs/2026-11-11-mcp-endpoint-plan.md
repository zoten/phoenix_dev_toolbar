# Loopback-only MCP endpoint

ADR 15 is the source of truth; this plan records the intent at the start.

Roadmap item: "(L) Loopback-only MCP endpoint". Coding agents (Claude Code,
Codex, Cursor, VS Code) connect to `http://localhost:4000/__pdt/mcp` and call
read-only tools over `PhoenixDevToolbar.Report` (ADR 13), without Tidewave, a
remote shell or a browser. Installation instructions for those clients ship in
the README, the usage rules and the skill.

## Decision (ADR 15)

- **Served by the plug** at `<path>/mcp`, on by default whenever the toolbar is
  on; `config :phoenix_dev_toolbar, mcp: false` turns it off (then 404). No
  router, no new dependency: JSON goes through `Phoenix.json_library/0`, as the
  Ecto export does.
- **Streamable HTTP, JSON responses only, stateless.** No SSE, no sessions.
  `POST` only; `GET` and `DELETE` get 405 (`allow: POST`). A notification (no
  `id`) gets 202 with no body. Batches (JSON arrays) get 400 `-32600`.
- **Both protocol eras on one endpoint** (the 2026-07-28 lifecycle allows it):
  - Legacy (2025-03-26, 2025-06-18, 2025-11-25): `initialize` answers the
    client's version when supported, else `2025-11-25`, with
    `capabilities: {tools: {listChanged: false}}`, `serverInfo`, `instructions`.
    `notifications/initialized` gets 202. A non-initialize request whose
    `MCP-Protocol-Version` header names an unsupported version gets 400; a
    missing header is accepted (2025-03-26). Unknown method: 200 with `-32601`.
  - Modern (2026-07-28): a request whose `params._meta` carries
    `"io.modelcontextprotocol/protocolVersion"`. Unsupported version: 400,
    `-32022`, `data: %{supported: [...], requested: v}`. The
    `MCP-Protocol-Version` header must equal it, `Mcp-Method` must equal the
    method, `Mcp-Name` must equal `params.name` on `tools/call`; otherwise 400,
    `-32020` (HeaderMismatch). `server/discover` returns `supportedVersions`
    (all four), `capabilities`, `instructions` and
    `_meta["io.modelcontextprotocol/serverInfo"]`. Results of `tools/list` and
    `tools/call` add `resultType: "complete"`. Unknown method: 404 with `-32601`.
  - `ping` returns `{}` in both eras.
- **Guards, in order**: toolbar enabled (a disabled toolbar passes the request through) and `mcp` not false (else 404);
  `HostCheck.allowed?/1` (403, the DNS rebinding guard); the peer
  (`conn.remote_ip`) is loopback (`ClientPolicy.loopback?/1`) and the request
  carries no proxy header (`x-forwarded-for`, `x-forwarded-host`,
  `x-forwarded-proto`, `x-real-ip`, `forwarded`) (403); an `Origin` header, when
  present, is the request's own origin or listed in `allowed_origins:` (403;
  CLI clients send none); method `POST` (405); content type `application/json`
  (415); body at most 1 MB (413). CORS headers are stripped as for the panel.
- **Body**: read with `Plug.Conn.read_body/2` (the plug runs before
  `Plug.Parsers` in a generated endpoint). If the host parsed it already
  (`conn.body_params` not `%Plug.Conn.Unfetched{}`), use that (`"_json"` for
  arrays).
- **Tools** (all `annotations: %{readOnlyHint: true}`, JSON Schema inputs with
  `additionalProperties: false`). A page is chosen by `sid`, else by `path`
  (newest page at that exact path), else the newest page; a connected mount
  resolves to its request, as the standalone panel does (ADR 14):
  - `list_pages`: `path`, `path_prefix`, `limit` (1..50, default 10). Sessions
    newest first, each with an absolute `panel_url`.
  - `page_summary`: `sid`, `path`. `Report.summary/2` plus `panel_url`.
  - `page_queries`: `sid`, `path`, `limit` (1..200, default 50), `sort`
    (`"order"` default, `"slowest"`). `%{total, returned, queries}`.
  - `page_callbacks`: same arguments and shape as `page_queries`.
  - `page_n_plus_one`: `sid`, `path`.
  - `page_errors`: `sid`, `path`, `limit` (1..100, default 20).
  - No page found, or invalid arguments: a result with `isError: true` and a
    message that says what to do ("load the page first; data expires after 10
    minutes"). Unknown tool: `-32602`.
  - Results: `structuredContent` (2025-06-18 and later) plus the same JSON as a
    `text` content block (all versions).
- **JSON safety**: every value goes through one normalizer: map keys to
  strings, module atoms to `inspect/1`, other atoms to strings (`nil`, `true`,
  `false` kept), `DateTime` to ISO 8601, pids, refs, tuples to `inspect/1`,
  invalid UTF-8 binaries to `inspect/1`. Never `String.to_atom/1` on input.
- **Sid input** must match `\A[A-Za-z0-9_-]{1,64}\z`, paths are compared as
  strings, `path_prefix` through `Regex.escape/1`.

## Modules

- `PhoenixDevToolbar.PageLookup` (internal): the page resolution now private in
  `PhoenixDevToolbar.Plug` (`newest_page/1`, `request_parent/2`), extended with
  `path_prefix`. Used by the plug and the tools.
- `PhoenixDevToolbar.OriginCheck` (internal): `same_origin?/1` and
  `allowed_origin?/1` moved out of `PanelSocket` (lines 73 to 150), plus
  `proxied?/1` for a `Plug.Conn`.
- `PhoenixDevToolbar.Mcp.Json` (internal): the normalizer, `encode!/1`, `decode/1`.
- `PhoenixDevToolbar.Mcp.Tools` (internal): definitions and `call/3` over
  `Report` and `PageLookup`. Pure, no conn.
- `PhoenixDevToolbar.Mcp.Protocol` (internal): `handle(message, headers, opts)`
  returns `{status, body_map | nil}`. Pure, no conn.
- `PhoenixDevToolbar.Mcp.Endpoint` (internal): the guards, body read and
  response, called from `PhoenixDevToolbar.Plug` for `["mcp"]`.
- `Config`: `mcp?/0` (default true) and a boot warning for an invalid value.

## Batches

1. **Pure core** (one agent): `PageLookup` (plug refactored to use it),
   `Mcp.Json`, `Mcp.Tools`, `Mcp.Protocol` with unit tests. No HTTP.
2. **HTTP** (one agent, then the combined reviewer): `OriginCheck` extraction
   (PanelSocket behavior unchanged, its tests green), `Mcp.Endpoint`, the plug
   route, `Config.mcp?/0`, `plug_test`-style tests for every guard and both
   eras through `Plug.Test`.
3. **Docs and check** (orchestrator): ADR 15, ADR 04/13/14 pointers, plug
   moduledoc "MCP" section, README "MCP server" with client setup (Claude Code
   `claude mcp add --transport http`, `.mcp.json`, Codex `config.toml`
   `url =`, Cursor `.cursor/mcp.json`, VS Code `.vscode/mcp.json`), usage
   rules and skill, CHANGELOG, roadmap. Then `mix precommit`,
   `agent-tools/ci-min.sh`, and a `curl` session against `mix dev` in both
   eras. Final `feature-review` over the range.

## Risks

- **Hot path**: none. The endpoint runs only for `<path>/mcp`, untracked
  (`Attribution.untrack/0`), so its Report reads are never recorded; telemetry
  handlers are untouched. Reads are ETS only, no GenServer call (ADR 13).
- **Production footprint**: none; everything sits behind the plug and
  `enabled?/0`. No new dependency (`Phoenix.json_library/0`).
- **Memory bounds**: the body is capped at 1 MB; tool output is capped by
  `limit` (max 200 rows, each row already truncated in the Store, ADR 03).
  No state between requests.
- **Security**: it exposes what the panel exposes, to fewer clients: loopback
  peer only, no proxy headers, a Host that cannot be rebound, and no foreign
  `Origin`, so a web page cannot reach it from the developer's browser (a JSON
  POST needs a CORS preflight, which is never granted). Read-only: no EXPLAIN,
  no process actions, no eval. Docker setups (non-loopback peer) are refused;
  noted as an open limit.
- **Host conflicts**: a host route at `<path>/mcp` is shadowed, as every path
  under `<path>` already is. A host `Plug.Parsers` before our plug is handled.
- **Public API and docs**: the endpoint URL, tool names, arguments and result
  keys are a contract like `Report` (adding is fine, renaming needs a CHANGELOG
  line). Protocol drift: new MCP revisions may need a version added.
- **Tests and ADR sync**: unit tests for Protocol and Tools, HTTP tests for
  every guard, PanelSocket tests unchanged after the extraction, ADR 15.
