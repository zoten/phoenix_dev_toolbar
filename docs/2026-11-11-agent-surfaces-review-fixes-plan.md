# Agent surfaces: review fixes

From the feature review of 92017aa..HEAD (ADR 14, ADR 15). Owner decisions:
gate sid-less panel resolution like MCP; align `actions:` and Eval `clients:`
on one `:local` rule.

## Decisions

- **One client rule** (`ClientMatch.allowed?/4`, done): `:local` is loopback or
  one of this machine's own interface addresses, never through a proxy;
  `{:list, entries}` adds IPs and CIDRs; `:any` is anyone.
- **Panel gate** (ADR 14): `?path=` and a bare `<path>/panel` resolve a page only
  for a client the MCP rule accepts (`Config.mcp/0`, `:off` counting as
  `:local`). Others get the panel with no page and a hint: open it from the
  page's toolbar (its iframe carries the sid), or allow the client with
  `mcp: [clients: [...]]`. `?sid=` is unchanged (the iframe, phones).
- **`actions:` and Eval `clients:`** (ADR 10, Eval plugin): `:local` replaces
  `:loopback` as the documented value; `:loopback` stays accepted and means
  `:local`. Eval's default becomes `:local`. A proxied panel socket has no
  client address (as today), so it is refused.
- **Messages**: the MCP client refusal names the peer address and has a proxy
  variant ("only `clients: :any` accepts proxied requests"), logged once per
  address like `HostCheck.log_refused/1`. A tool with `path` and no page says
  "No captured page at `<path>`" and points at `list_pages` and the live patch
  rule (a patch keeps its LiveView's mount path). The standalone panel's empty
  state says what was asked (`?path=`, newest, gated) instead of "it expired".
- **Nits**: `panel_url` omits the port for 80 and 443; `?path[]=` is the empty
  state, not the newest page; `PanelLive` uses `PageLookup.valid_sid?/1`.

## Batches

- **A, panel and MCP** (Sonnet, then one Opus review with B): `plug.ex`,
  `panel_live.ex`, `panel_layout.ex`, `mcp/endpoint.ex`, `mcp/tools.ex`, their
  tests, plus one MCP test that starts from a real tracked GET through the plug.
- **B, actions and Eval** (Sonnet): `client_policy.ex`, `plugins/eval.ex`,
  `panels/eval.ex`, `process_actions.ex` if it names modes, their tests.
- **C, docs** (orchestrator): README "Docker or LAN access" as the one place for
  the access story, SECURITY.md (MCP), ADR 04, 10, 14, 15, plug moduledoc
  (the `data-pdt-*` table), usage rules, CHANGELOG.

## Risks

- **Security**: the gate narrows exposure; `:loopback` meaning `:local` widens
  actions and Eval to the machine's own LAN address, which only this machine
  can use (ADR 15 reasoning), plus local relays, as loopback already allowed.
- **Host safety**: `own_addresses/0` runs only for a peer that is neither
  loopback nor listed, on panel loads, MCP requests and action checks, never
  in telemetry handlers. It never raises.
- **Compatibility**: existing `:loopback` configs keep working; the Eval default
  widens to `:local` (CHANGELOG line).
- **Tests**: gate allowed/refused per mode, messages, actions/Eval with an
  own-address peer (injected address list), the real-GET MCP test.
