# ADR 04: UI Delivery: Isolated Iframe LiveView and Loader

**Status:** Implemented (2026-11-05)  
**Area:** ui  
**Related:** [ADR 01](./01-zero-prod-footprint-and-installation.md) (install), [ADR 03](./03-event-storage.md) (data source)

## Context

The toolbar must appear on every page without the host editing templates or
`app.js`, must not be styled by the host's CSS (nor style it), and must not
interfere with the host's LiveSocket, DOM patching or CSP.

## Decision

- **Page requests**: `PhoenixDevToolbar.Plug` (endpoint, before the router, options
  `:path` default `"/__pdt"` and `:nonce_assign` default `:csp_nonce`) tracks a request as
  a page when it is a `GET` for a top level document: `sec-fetch-dest: document`, or,
  for clients without that header, an `Accept` containing `text/html`. Iframes, fetch,
  htmx and Turbo partials, `/phoenix/live_reload/*` and the toolbar's own routes are not
  pages. Any other request clears the previous request's mark from the connection
  process (keep-alive). A conn already tracked (plug present twice) is left alone.
- **Injection**: a `before_send` callback inserts one
  `<script defer src="<path>/assets/loader.js" data-pdt-sid="..." data-pdt-path="<path>">`
  before the last `</body>` (the `Phoenix.LiveReloader` technique), only for
  `send_resp` (not chunked, not `send_file`) 200 `text/html` responses without a
  `content-encoding` other than `identity`. The tag gets `nonce` from the assign when it
  is a string; every attribute is HTML escaped. A stale `etag` is removed. The callback
  also records a `:response` event (status, content type, `injected?`, total duration),
  then drops the connection process from the `$callers` index while keeping its mark
  for the `router_dispatch :stop` event. Any failure leaves the response untouched.
- **Assets**: the plug serves a whitelist under `<path>/assets/` and halts; anything
  else, or a missing file, is a 404. Ours (`loader.js`, `panel.js`, `panel.css`) come from
  our `priv/static`; `phoenix.js` and `live_view.js` are the host's own installed
  `phoenix.min.js` and `phoenix_live_view.min.js` (UMD builds shipped by both packages
  since LiveView 1.1), so the panel's JS client always matches the host's server
  versions: the LiveView client warns on any version mismatch with the server. The
  host's asset pipeline is never involved. Sources live in `assets/`; `mix assets.build`
  (esbuild, a dev only dependency, `--bundle --minify --target=es2020 --format=iife`)
  writes our bundles, which are committed and shipped in the package. CI rebuilds them
  and fails when `priv/static` differs. `panel.css` is hand written, no CSS framework.
- **Robustness**: `:path` must be absolute and below the root (raises in `init/1`); while
  the Store restarts every request is served untracked.
- **Loader** (plain JS, about 9 KB minified, under 4 KB gzipped): runs only in the top window and once per
  page. It adds a single `div#phoenix-dev-toolbar` (`data-phx-update="ignore"`) to
  `<body>` whose open shadow root holds its style and the panel `<iframe>`
  (`<path>/panel?sid=...`), a resize handle and a corner pill, so host CSS and toolbar CSS
  cannot meet. Three states, persisted in the host origin's `localStorage` (`pdt:state`; the
  old `pdt:open` key is migrated): `collapsed` (default: the iframe is a 34px bar, the panel
  header), `open` (the panel at its size, see Docks), `hidden` (no iframe, only a small
  "dev toolbar" pill in the bottom right corner, so the bar never permanently covers the
  host page; clicking it collapses again). The iframe asks for `pdt:toggle` (toggle
  button), `pdt:open` (a tab was picked), `pdt:hide` (hide button) and `pdt:dock` (dock
  picker, a known dock only); the loader answers with `pdt:state` (`open` and `dock`).
  Both sides check `event.origin` and `event.source`. The loader also forwards LiveView's
  own `phx:*` window events as `pdt:client` messages (passive listeners, sanitized, rate
  limited: ADR 07). Phase 4 adds host socket RTT through
  `window.liveSocket.getSocket().ping/1` when it exists, read only. Page
  correlation, including live navigation, happens server side (ADR 02), so the
  toolbar keeps working when the loader cannot reach `window.liveSocket`.
- **Docks and page space**: the toolbar docks `bottom` (default), `top`, `left` or `right`,
  picked from a client side menu in the open panel header (`#pdt-dock`). Each dock makes
  room so the page never hides under the bar: 34px collapsed, the panel size open,
  nothing hidden.
  - `bottom` and `top`: the host div stays in the page flow with that inline height, as
    the last child of `<body>` (the page scrolls its end above the bar) or the first (it
    pushes the page down).
  - `left` and `right`: a block cannot reserve width, so the loader sets an inline
    `padding-left` or `padding-right` on `<html>`: the host's computed padding plus the
    toolbar, `!important`. This is the toolbar's **only write to a host element**: the
    host's own inline value is put back whenever the dock changes or the toolbar hides.
  - Limits: reserving space only helps when the document is the scroller (an app shell
    that scrolls an inner `overflow: auto` container stays covered), host
    `position: fixed` chrome stays under the panel, and on side docks the host's media
    queries still see the full window width. Collapse, resize or hide are the fallback.

  The open size is draggable from a handle on the panel's inner edge
  (`role="separator"`; arrows step 16px, Shift 64px, Home or double click reset), clamped
  between a minimum (120px top/bottom, 280px left/right) and the viewport minus a 48px
  strip of page, re-clamped on window resize. Defaults: `min(45vh, 520px)` top/bottom,
  `min(40vw, 480px)` left/right. The iframe ignores pointer events while dragging. The
  layout is persisted as `pdt:layout` (`{"dock": ..., "sizes": {dock: px}}`, one size per
  dock; the older `{"dock", "size"}` shape is read back). Sizing and parsing live in
  `layout.mjs`. In the panel, `panel.js` sets `pdt-dock-<name>` (and `pdt-side`) on its
  root: collapsed on a side, the header turns into a full height strip
  (`writing-mode: vertical-rl`, header sizes are logical properties), and an open panel
  under 560px wide puts the tabs on their own row.
- **Panel JS**: the root layout loads, deferred and in order, `phoenix.js`, `live_view.js`
  and `panel.js` (about 1 KB: no client bundled). `panel.js` takes `window.Phoenix` and
  `window.LiveView`, connects the panel through its own socket (`<path>/live`, see Panel
  socket: WebSocket only, no CSRF param) and runs the `postMessage` side of the bridge. Its `PdtPanel` hook, on the empty `#pdt-bridge`
  element, reports visibility and forwards client events to `PanelLive` (ADR 07).
- **Panel route**: there is no router integration (ADR 01). The plug answers
  `GET <path>/panel?sid=...` itself with `Phoenix.LiveView.Controller.live_render/3`
  (other methods get a 405), passing the sid in the signed LiveView session, with the
  `PhoenixDevToolbar.Layouts.root/1` root layout. The layout loads only `panel.css` and
  `panel.js`, at URLs built from the plug's configured `:path` (never from the request
  path: `//__pdt/panel` also reaches the panel and would yield a protocol relative URL
  to another host), and passes `<path>/live` to `panel.js`. The plug runs before the
  host's `Plug.Session` in a generated endpoint, so the panel never touches the cookie
  session (LiveView treats an unfetched session as empty).
- **Panel downloads**: `GET <path>/export/ecto.json` answers the Ecto tab's Download as
  an attachment (ADR 08). Downloads use same-origin URLs, never `blob:` links: Firefox
  checks a link clicked in the iframe against the host's `frame-src`.
- **Panel socket**: `PhoenixDevToolbar.PanelSocket`. The plug upgrades
  `GET <path>/live/websocket` itself, through Phoenix's documented custom transport API:
  `Phoenix.Socket.Transport.check_origin/4` and `connect_info/3`, then
  `Phoenix.LiveView.Socket.connect/1` and `WebSockAdapter.upgrade/4`, with Phoenix's
  default WebSocket options (JSON serializers 1.0 and 2.0, 60 s timeout). The host
  socket's own `websocket:` options that apply here (`check_origin`, `timeout`,
  `max_frame_size`) override those defaults, so the origin policy is the host socket's,
  falling back to the endpoint's. It uses the host endpoint (PubSub, secret key base,
  LiveView's session verification) and the endpoint's mounted LiveView socket handler
  (`Phoenix.LiveView.Socket`, or a host module that uses it), but its `connect_info`
  has no session. An endpoint without a LiveView socket gets a 404 and one warning; a
  host still passing the removed `:live_socket_path` gets one warning.
  - Panels only: the handler is wrapped as a `WebSock` that decodes every text frame
    (an escaped event name is still a join) and refuses binary frames. A `phx_join` goes
    through only for `lv:<id>` where a panel's dead render registered `id`
    (`Store.allow_panel/1`, a day at most, 1000 panels at most enforced on insert; LiveView
    checks that the topic is the id signed in the session token). Any other `lv:` join
    (a host LiveView, or a panel the Store forgot after a restart) gets LiveView's own
    `stale` reply: the panel reloads, its new dead render registers it, and the breaker
    caps any loop. Any other topic (uploads, channels) closes the connection. The
    session free socket never becomes a way into the host's own LiveViews, whose tokens
    would otherwise join without the host's CSRF and session checks.
  - Why: the host's own socket, configured with `connect_info: [session: ...]` as every
    generated app is, gets a session only when the `_csrf_token` param matches the CSRF
    state in the session cookie. Without one, LiveView refuses every join with `stale`,
    and its client then sends the iframe to its own URL at once (outside its throttled
    reload). A page without a CSRF meta tag, no session cookie yet, or a session renewed
    in another tab (log in or out) put the panel in a reload loop.
  - Security: the socket carries no session, so it gives nothing tied to the user's
    login and reads nothing from it. Joining the panel needs its signed LiveView session
    token (the sid inside, see Access), which only the panel's HTML holds and another
    origin cannot read; the host socket's `check_origin` applies to the upgrade.
- **Reload breaker** (`assets/js/reloads.mjs`, the safety net for any join failure,
  present or future): each panel load is recorded per sid in `sessionStorage`. The 4th
  load within 10 s does not connect and shows, in the header (so in the collapsed bar
  too), a short "Cannot connect" (the full reason in its tooltip and for screen
  readers) with a Retry button that clears the record; the tabs are dimmed and inert
  meanwhile. A panel that has not joined 8 s after connecting (its WebSocket refused or
  blocked, which never reloads) shows the same notice until it joins. A joined panel
  forgets its record; other pages' records past the window are pruned on load. Storage
  blocked: no breaker, never an error.
- **Lost connection**: once joined, a panel whose socket drops (LiveView's
  `phx-client-error` or `phx-server-error` on its root) shows "Disconnected ·
  reconnecting" in the header and dims its data, which is frozen until LiveView
  rejoins on its own. Pure CSS on a server rendered element (`#pdt-offline`).
- **Panel**: `PhoenixDevToolbar.PanelLive` (`<path>/panel?sid=<request sid>`) shows one
  page: the request and its LiveView, or only the newest LiveView after live navigation.
  `PhoenixDevToolbar.Page` derives the page once at mount (catching up with navigation
  that happened before the panel opened) and then only moves forward on
  `{:pdt_session, sid}` notifications: `:connected` (first LiveView of the request),
  `:navigated` (a child of the current LiveView on the same transport, or at another
  path: a duplicated tab rejoins at the same path and is ignored), `:rejoined` (the
  current LiveView reconnected). It never re-derives the page from the root, so the
  root expiring (TTL, eviction) or an older LiveView expiring does not affect it.
  The panel subscribes to the root before reading, so a LiveView connecting during
  mount is not missed, and to every sid shown. It re-reads new events at most every
  100 ms, including a window of 64 seqs below the last one seen (seqs are allocated
  before their row is written, so concurrent writers can land out of order), skipping
  seqs already shown (remembered per sid, only within that sid's window). Each tab is a plugin's `PhoenixDevToolbar.Panel` component, fed
  its plugin's events (ADR 05); lists are LiveView streams capped at 500 rows. The
  summary bar shows the plugins' badges, folded incrementally (query count and database
  time, status and duration, router errors, LiveView callbacks), "+N dropped" when the
  flood guard discarded events and "N older trimmed" past the caps, so counts are never
  silently low. The bar is one row: badges that do not fit wrap out of sight and a "+N"
  chip (`PdtSummaryMore` hook in `panel.js`) counts them; it opens the panel, whose
  header grows to show every badge. Tabs follow the configuration: Ecto, Request, LiveView (ADR 07) and any
  third party plugin, as WAI-ARIA tabs
  (`aria-controls`, `tabpanel`, roving `tabindex`, arrow keys in `panel.js`). Each query
  row says where it ran (`HTTP` for the dead render, `live` for the connected LiveView)
  and its details show params, repo, the queue/query/decode/idle timings and the origin
  stacktrace, or a hint to enable `stacktrace: true` in the repo config. An invalid or
  expired sid, or the Store restarting, shows an explanation, not an error.

- **Access**: the sid is the only key to a page's data. It is 96 random bits, never
  listed or enumerable, and reaches the panel only through the injected tag and the
  signed LiveView session: a bearer capability, adequate for a dev only tool on the
  developer's machine. There is no other access control. The panel page answers with
  `content-security-policy: frame-ancestors 'self'` (only the host page's own origin
  may frame it) and, like every served asset, `x-content-type-options: nosniff`.

## Consequences

- Full CSS/JS isolation, no conflicts with host Tailwind, DaisyUI, hooks or `morphdom`.
- Costs one extra WebSocket connection per page in dev, acceptable for a dev tool.
- The panel works on every page the plug serves, whatever the host's session, CSRF and
  socket configuration (the host's socket path no longer matters).
- When it still cannot connect, it says so instead of reloading.
- The panel cannot inspect the host DOM directly; anything DOM related goes through the loader.

## Open limits

- The panel's JS runs only in a real browser (checked by hand in `mix dev`); CI's
  LiveView 1.1 row covers the server side through `LiveViewTest` and checks that the
  host client files exist, but does not execute them.
- Strict CSP without a nonce (or `frame-src` restrictions) blocks the toolbar silently.
- No long poll fallback: a proxy that blocks WebSockets leaves the panel unconnected
  (the breaker's notice says so).
- The panel socket mirrors Phoenix's WebSocket defaults by hand: a new Phoenix default
  (a serializer version) needs a change here. It skips what the panel does not need:
  code reloading on connect, subprotocols, and the pool drainer (panel connections
  close abruptly as the endpoint stops).
- The upgrade from a plug is tested with Bandit only; Cowboy relies on the same halted
  conn contract.
- A panel left open for more than a day, or pushed out by 1000 newer panel renders,
  reloads on its next rejoin (its id is gone, so it gets `stale`).
- Pages that are not HTML responses from Plug (static files) get no toolbar.
