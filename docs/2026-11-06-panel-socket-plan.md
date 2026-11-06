# Panel socket plan: no reload loop, no dependency on the host's CSRF token

Goal: the panel connects on every host page, and when it cannot, it says so instead
of reloading in a loop. Decisions go into ADR 04 (UI delivery) and ADR 01 (install:
`:live_socket_path` goes away).

## The bug

- The panel connects through the host's LiveView socket. Configured with
  `connect_info: [session: ...]` (every generated app), Phoenix gives the connection
  a session only when the `_csrf_token` param matches the session cookie's CSRF state
  (`deps/phoenix/lib/phoenix/socket/transport.ex`, `connect_session/4`).
- Without one, LiveView answers every join with `stale` (`channel.ex`, `mount/3`),
  and the client goes to `window.location.href` at once (`view.ts`, `onJoinError`),
  outside its throttled reload.
- `panel.js` sends the host page's meta token, or ours, which never matches.

The loop happens on a page without a CSRF meta tag (`/plain` in the harness), and
after a session renewal in another tab (log in or out): the host page keeps its old
token, so every panel reload sends it again.

## Changes

**A. Reload breaker** (`panel.js`, a pure helper in `assets/js/reloads.mjs`).
- Each panel load records its time per sid in `sessionStorage`. The 4th load within
  10 s does not connect.
- In that case the panel shows "The toolbar cannot connect to this page" with a
  Retry button, which clears the record and reloads.
- A successful join clears the record.
- Storage blocked: no breaker (as today), never an error.
- This is a safety net for any join failure, present or future.

**C. The panel's own socket** (`PhoenixDevToolbar.PanelSocket`, called by the plug).
- `GET <path>/live/websocket` is upgraded by the plug itself. It goes through the
  public `Phoenix.Socket.Transport` API (`check_origin/4`, `connect_info/3`), then
  `Phoenix.LiveView.Socket.connect/1` and `WebSockAdapter.upgrade/4`, as Phoenix's own
  WebSocket transport does.
- The host endpoint is used and its `check_origin` applies.
- `connect_info` carries no session, so there is no CSRF check and no session data.
- `panel.js` connects there, WebSocket only (no long poll fallback) and with no CSRF
  param. `:live_socket_path` goes away.
- `websock_adapter` becomes a declared dependency (it already comes with Phoenix).

## Tasks

1. **(R) A.** The helper with node tests; `panel.js` wiring; the fallback markup and
   CSS. Browser check on `/plain`, before C lands, to see it trip.
2. **(R) C.**
   - The `PanelSocket` module, the plug route and `panel.js`.
   - Tests:
     - an end to end WebSocket test: Bandit in test, a minimal `:gen_tcp` client that
       joins the panel LiveView, with no session cookie and no CSRF param;
     - a foreign origin is refused when `check_origin` is set;
     - a non upgrade GET gets a 400.
   - Browser check on `/plain` and after a session renewal (cookie cleared while open).
3. **Docs.** ADR 04 (both behaviours, the security argument), ADR 01, README and
   CHANGELOG; precommit, LiveView 1.1, the fixture builds, then a final review.

## Risks

- **Security:** the socket carries no session, so nothing tied to the user's login;
  joining still needs the panel's signed LiveView session token, only in the panel's
  HTML (same origin). `check_origin` follows the endpoint's.
- **Host conflicts:** our path is under `:path` (`/__pdt` by default), inside the
  plug's `code_reloading?` block. Nothing changes in the host's socket.
- **Version compatibility:**
  - `Phoenix.Socket.Transport` functions and `handler.connect/1` are documented for
    custom transports;
  - the serializer list mirrors Phoenix's default;
  - verify against Phoenix 1.8 (our minimum) and LiveView 1.1 and 1.2.
- **Proxies without WebSocket support:** there is no long poll fallback. The breaker
  shows why.
- **Production footprint:** none. The route is answered by the plug that is only in
  `code_reloading?`.
