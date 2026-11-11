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
  is a string; every attribute is HTML escaped. A stale `etag` and `content-length` are removed. The callback
  also records a `:response` event (status, content type, `injected?`, total duration),
  then drops the connection process from the `$callers` index while keeping its mark
  for the `router_dispatch :stop` event. Any failure (error, throw or exit) is logged and leaves the response untouched.
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
  picker, a known dock only) and `pdt:reserve` (a boolean); the loader answers with
  `pdt:state` (`open`, `dock` and `reserve`).
  Both sides check `event.origin` and `event.source`. The loader also forwards LiveView's
  own `phx:*` window events as `pdt:client` messages (passive listeners, sanitized, rate
  limited: ADR 07). Page
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
    that scrolls an inner `overflow: auto` container stays covered, and a full height
    shell gains a 34px document scroll), host `position: fixed` chrome stays under the
    panel, a `<body>` laid out as a flex row gives the bar no room, and on side docks the
    host's media queries still see the full window width. Collapse, resize or hide are
    the fallback.
  - Opt out: reserving is on by default. `config :phoenix_dev_toolbar, reserve_space:
    false` turns it off (the plug writes `data-pdt-reserve="false"` on the loader tag),
    and the dock menu's "Reserve page space" toggle (`#pdt-reserve`, `pdt:reserve`)
    overrides the config per browser, stored in `pdt:layout` as `reserve`. Not
    reserving, the bar overlaps the page and `<html>` is never written.

  The open size is draggable from a handle on the panel's inner edge
  (`role="separator"`; arrows step 16px, Shift 64px, Home or double click reset), clamped
  between a minimum (120px top/bottom, 280px left/right) and the viewport minus a 48px
  strip of page, re-clamped on window resize. Defaults: `min(45vh, 520px)` top/bottom,
  `min(40vw, 480px)` left/right. The iframe ignores pointer events while dragging. The
  layout is persisted as `pdt:layout` (`{"dock": ..., "sizes": {dock: px}, "reserve"?:
  bool}`, one size per dock; the older `{"dock", "size"}` shape is read back). Sizing and parsing live in
  `layout.mjs`. In the panel, `panel.js` sets `pdt-dock-<name>` (and `pdt-side`) on its
  root: collapsed on a side, the header turns into a full height strip
  (`writing-mode: vertical-rl`, header sizes are logical properties), and an open panel
  under 560px wide puts the tabs on their own row.
- **Panel JS**: the root layout loads, deferred and in order, `phoenix.js`, `live_view.js`
  and `panel.js` (about 8.5 KB: no client bundled; `loader.js` is about 9.5 KB and `panel.css` about 17 KB). `panel.js` takes `window.Phoenix` and
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
  session (LiveView treats an unfetched session as empty). Without `?sid=` the plug
  picks the page itself (`?path=`, or the newest), and `panel.js` opened outside the
  iframe runs standalone: ADR 14.
- **MCP**: `<path>/mcp` is the toolbar's MCP server for coding agents, for
  this machine by default, with its own guards and protocol rules: ADR 15.
- **Panel downloads**: `GET <path>/export/ecto.json` answers the Ecto tab's Download as
  an attachment (ADR 08). Downloads use same-origin URLs, never `blob:` links: Firefox
  checks a link clicked in the iframe against the host's `frame-src`.
- **Panel socket**: `PhoenixDevToolbar.PanelSocket`. The plug upgrades
  `GET <path>/live/websocket` itself, through Phoenix's documented custom transport API:
  `Phoenix.Socket.Transport.connect_info/3`, then
  `Phoenix.LiveView.Socket.connect/1` and `WebSockAdapter.upgrade/4`, with Phoenix's
  default WebSocket options (JSON serializers 1.0 and 2.0, 60 s timeout). The host
  socket's own `websocket:` options `timeout` and `max_frame_size` override those
  defaults; its `check_origin` does not apply (see the origin rule below). It uses the host endpoint (PubSub, secret key base,
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
    origin cannot read; the upgrade is refused unless its `Origin` is the page's own (origin rule).
  - Origin rule: the panel iframe is always same origin with its page, so the plug
    enforces that itself, whatever the host's `check_origin` says (generated dev
    configs set it to `false`). The upgrade needs exactly one `Origin` header with an
    `http` or `https` scheme and the same host as the request's `Host` header
    (case-insensitive), else a 403 with one log line. The port must match the `Host`
    header's port, or be a default port (80, 443) when `Host` names none. The scheme
    is not compared with the request's, because a TLS terminating proxy or tunnel
    changes it. A missing `Origin` is refused. A proxy or tunnel that rewrites the
    `Host` header breaks the match, so an `Origin` listed in `allowed_origins:`
    (`"https://abc.tunnel.example"`) passes whatever the `Host` says: matched exactly
    on scheme, host (case-insensitive) and port (default ports filled in), no
    wildcards, since each entry widens who may open the socket. Entries are checked
    once at boot: one an `Origin` header cannot carry (no scheme, a path, a query,
    user info, a `*`) is logged and dropped. The Host guard below still applies to the rewritten `Host`. `access-control-*` response headers
    set by the host are removed from the panel and export responses.
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
  listed or enumerable to another device, and reaches the panel only through the
  injected tag and the signed LiveView session: a bearer capability, adequate for a
  dev only tool on the developer's machine. Finding a page without its sid (the
  standalone panel's `?path=` and newest page, ADR 14, and the MCP tools, ADR 15)
  is limited to this machine unless `mcp: [clients: ...]` says otherwise. The panel page answers with
  `content-security-policy: frame-ancestors 'self'` (only the host page's own origin
  may frame it) and, like every served asset, `x-content-type-options: nosniff`.
- **Host guard** (`HostCheck`, against DNS rebinding): a hostile page whose name
  re-resolves to 127.0.0.1 would read the panel as same origin. Under rebinding the
  `Origin` and the `Host` both name the attacker's host and match, so the origin rule
  does not stop it: only this guard does. The origin rule stops pages from other
  origins (other sites, other local ports) reaching an allowed host. Both are required
  on the socket path (the guard runs in the plug, before the upgrade). The panel, its
  socket and the export answer only for a Host that cannot be rebound: an IP literal,
  `localhost` and `*.localhost`, the endpoint's `url: [host: ...]`, or one listed in
  `allowed_hosts:` (`"myapp.test"`, or `".test"` for every name under it). Any other
  gets a 403 that says how to allow it, logged once per boot. Assets stay public.

## Consequences

- Full CSS/JS isolation, no conflicts with host Tailwind, DaisyUI, hooks or `morphdom`.
- Costs one extra WebSocket connection per page in dev, acceptable for a dev tool.
- The panel works on every page the plug serves, whatever the host's session, CSRF and
  socket configuration (the host's socket path no longer matters).
- When it still cannot connect, it says so instead of reloading.
- The panel cannot inspect the host DOM directly; anything DOM related goes through the loader.

## Open limits

- The loader and panel wiring is tested against a fake DOM (ADR 06), not a real
  browser: rendering and the host's LiveView client are checked by hand in `mix dev`.
  CI's LiveView 1.1 row covers the server side through `LiveViewTest` and checks that the
  host client files exist, but does not execute them.
- A strict CSP needs the nonce (`:nonce_assign`): the loader copies the injected script's
  nonce to its shadow `<style>`, so one nonce covers the script and the frame styling. The
  panel iframe is its own document served with its own headers, so the host's `script-src`
  and `style-src` do not apply to it. A `frame-src` or `child-src` that excludes the
  toolbar's own origin blocks the frame silently.
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
- A Host without a port accepts an Origin on port 80 or 443, and the scheme is not
  compared, so `http://localhost` and `https://localhost` are not told apart; the signed
  panel session token (unreadable cross-origin, CORS headers stripped) remains the barrier.
- An `allowed_origins:` entry outlives the tunnel it named: a free tunnel name handed to
  someone else later passes the origin rule against `localhost`, and the panel token
  (unreadable cross-origin) is then the only barrier. The docs say to remove stale entries.
- A host plug that adds `access-control-*` headers from its own `register_before_send`,
  registered earlier than the toolbar plug, runs after the toolbar's stripping and can
  re-add them.
- HTTP/2 requests carry no `host` header; the fallback then requires a default port.
