# MCP clients: same machine by address, allowlist, any

ADR 15 is the source of truth once this lands; this plan records the intent.

A dev server bound to a LAN address (Hajime's `run.sh` sets `PHX_IP` to the
machine's LAN IP, so phones can reach it) is not listening on 127.0.0.1. An agent
on the same laptop reaches `http://192.168.x.y:4000/__pdt/mcp`, its peer address
is the laptop's own LAN address, and the loopback-only rule refuses it.

## Decision (ADR 15, edited in place)

`config :phoenix_dev_toolbar, mcp: ...`:

- `true` (default) or `[clients: :local]`: loopback peers and peers whose address
  is one of this machine's own interface addresses (`:inet.getifaddrs/0`, read
  per refused-by-loopback request, no cache). A packet from another device
  carries that device's address, so this is still "this machine only".
- `[clients: ["192.168.1.0/24", "10.0.0.7", "fd00::/8"]]`: `:local` plus these
  IPs and CIDR ranges (IPv4 and IPv6). Parsed with `:inet.parse_strict_address/1` and
  bit masks, never atoms; an invalid entry logs one boot warning and is ignored.
- `[clients: :any]`: any peer, proxy headers allowed too, one boot warning
  ("anyone who reaches this dev server can read the captured data").
- `false`: off (404).
- Anything else: one boot warning, treated as `true`.

IPv4-mapped IPv6 peers (`::ffff:a.b.c.d`) are compared as IPv4. Proxy headers
are refused for every mode but `:any` (the peer would be the proxy). The Host
and Origin guards are unchanged for every mode.

## Modules

- `PhoenixDevToolbar.ClientMatch` (internal, pure): `parse/1` an entry to
  `{:ok, {ip_tuple, prefix_bits}} | :error`; `matches?(peer, entries)`;
  `local?(peer, ifaddrs)` with injectable interface addresses for tests.
- `Config.mcp/0` returns `:off | :local | {:list, entries} | :any`;
  `Config.mcp?/0` stays (true unless `:off`); `warn_mcp/0` covers the new shapes.
- `Mcp.Endpoint` guard: replace the loopback clause with
  `client_allowed?(conn, Config.mcp())`.

## Tests

- `ClientMatch`: IPv4 and IPv6 CIDRs, /0, /32, /128, bare IPs, mapped IPv6,
  invalid entries (hostnames, `"300.1.1.1"`, `"10.0.0.0/33"`, non-strings).
- Endpoint: own-interface peer accepted (inject the address list), LAN peer
  refused by default, allowed by a CIDR, `:any` accepts a proxied request,
  proxy refused with a list, `mcp: false` still 404.
- Config: warnings for `:any` and invalid entries, once.

## Docs

ADR 15 decision and open limits (the container limit now has a remedy), README
"MCP server" (LAN-bound dev server note, `clients:` example), usage rules
symptom for 403 "loopback only", plug moduledoc, CHANGELOG line.

## Risks

- **Security**: `:local` widens nothing beyond this machine: an interface
  address match requires the TCP peer to be one of our addresses, which another
  device cannot complete a handshake as on a switched LAN. Lists are explicit
  and warned only when invalid; `:any` is warned at boot. Proxy headers stay
  refused outside `:any`.
- **Host process safety**: `:inet.getifaddrs/0` runs only for an MCP request whose
  peer is not loopback and not listed; it returns `{:error, _}` instead of
  raising, treated as "no local addresses". Parsing never raises.
- **Hot path, footprint, memory**: none; MCP requests only, no state kept.
- **Public API**: `mcp:` gains a keyword form; `true` and `false` keep working.
