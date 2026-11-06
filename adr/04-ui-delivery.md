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
- **Loader** (plain JS, about 4 KB minified, under 2 KB gzipped): runs only in the top window and once per
  page. It appends a single `div#phoenix-dev-toolbar` (`data-phx-update="ignore"`) to
  `<body>` whose open shadow root holds its style and the panel `<iframe>`
  (`<path>/panel?sid=...`) and a corner pill, so host CSS and toolbar CSS cannot meet.
  Three states, persisted in the host origin's `localStorage` (`pdt:state`; the old
  `pdt:open` key is migrated): `collapsed` (default: the iframe is a 34px bar, the panel
  header, fixed at the bottom), `open` (`min(45vh, 520px)`), `hidden` (no iframe, only a
  small "dev toolbar" pill in the bottom right corner, so the bar never permanently
  covers the host page; clicking it collapses again). The iframe asks for `pdt:toggle`
  (toggle button), `pdt:open` (a tab was picked) and `pdt:hide` (hide button); the
  loader answers with `pdt:state`. Both sides check `event.origin` and `event.source`. The
  loader also forwards LiveView's own `phx:*` window events as `pdt:client` messages
  (passive listeners, sanitized, rate limited: ADR 07). Phase 4 adds host socket RTT through
  `window.liveSocket.getSocket().ping/1` when it exists, read only. Page
  correlation, including live navigation, happens server side (ADR 02), so the
  toolbar keeps working when the loader cannot reach `window.liveSocket`.
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
- **Panel socket**: `PhoenixDevToolbar.PanelSocket`. The plug upgrades
  `GET <path>/live/websocket` itself, through Phoenix's documented custom transport API:
  `Phoenix.Socket.Transport.check_origin/4` (the endpoint's `check_origin`) and
  `connect_info/3`, then `Phoenix.LiveView.Socket.connect/1` and
  `WebSockAdapter.upgrade/4`, with Phoenix's default WebSocket options (JSON serializers
  1.0 and 2.0, 60 s timeout). It uses the host endpoint (PubSub, secret key base,
  LiveView's session verification) and the endpoint's mounted LiveView socket handler
  (`Phoenix.LiveView.Socket`, or a host module that uses it), but its `connect_info`
  has no session. An endpoint without a LiveView socket gets a 404 and one warning.
  - Panels only: the handler is wrapped as a `WebSock` that lets a `phx_join` through
    only for `lv:<id>` where a panel's dead render registered `id`
    (`Store.allow_panel/1`, a day and 1000 panels at most; LiveView checks that the
    topic is the id signed in the session token). Any other join (a host LiveView,
    uploads) closes the connection: the session free socket never becomes a way into
    the host's own LiveViews, whose tokens would otherwise join without the host's
    CSRF and session checks.
  - Why: the host's own socket, configured with `connect_info: [session: ...]` as every
    generated app is, gets a session only when the `_csrf_token` param matches the CSRF
    state in the session cookie. Without one, LiveView refuses every join with `stale`,
    and its client then sends the iframe to its own URL at once (outside its throttled
    reload). A page without a CSRF meta tag, no session cookie yet, or a session renewed
    in another tab (log in or out) put the panel in a reload loop.
  - Security: the socket carries no session, so it gives nothing tied to the user's
    login and reads nothing from it. Joining the panel needs its signed LiveView session
    token (the sid inside, see Access), which only the panel's HTML holds and another
    origin cannot read; the endpoint's `check_origin` applies to the upgrade.
- **Reload breaker** (`assets/js/reloads.mjs`, the safety net for any join failure,
  present or future): each panel load is recorded per sid in `sessionStorage`. The 4th
  load within 10 s does not connect and shows, in the header (so in the collapsed bar
  too), "The toolbar cannot connect to this page" with a Retry button that clears the
  record. A panel that has not joined 8 s after connecting (its WebSocket refused or
  blocked, which never reloads) shows the same notice until it joins. A joined panel
  forgets its record; other pages' records past the window are pruned on load. Storage
  blocked: no breaker, never an error.
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
  developer's machine. There is no other access control.

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
- A panel left open for more than a day cannot rejoin after a disconnect (its id
  expired): a reload fixes it.
- Pages that are not HTML responses from Plug (static files) get no toolbar.
