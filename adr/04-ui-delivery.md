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
  `:path` default `"/__pdt"`, `:live_socket_path` default `"/live"` and `:nonce_assign`
  default `:csp_nonce`) tracks a request as
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
- **Assets**: the plug serves a whitelist (`loader.js`, `panel.js`, `panel.css`) under
  `<path>/assets/` from `priv/static` and halts; anything else, or a missing file, is a
  404. The host's asset pipeline is never involved. Sources live in `assets/`;
  `mix assets.build` (esbuild, a dev only dependency, `--bundle --minify --target=es2020
  --format=iife`) writes the bundles, which are committed and shipped in the package.
  CI rebuilds them and fails when `priv/static` differs. `panel.js` bundles the
  `phoenix` and `phoenix_live_view` JS from `deps/` (NODE_PATH); `panel.css` is hand
  written, no CSS framework.
- **Robustness**: `:path` must be absolute and below the root (raises in `init/1`); while
  the Store restarts every request is served untracked.
- **Loader** (plain JS, under 2 KB minified): runs only in the top window and once per
  page. It appends a single `div#phoenix-dev-toolbar` (`data-phx-update="ignore"`) to
  `<body>` whose open shadow root holds its style and the panel `<iframe>`
  (`<path>/panel?sid=...`), so host CSS and toolbar CSS cannot meet. The iframe is fixed
  at the bottom: 34px collapsed (the panel header), `min(45vh, 520px)` open; the state
  persists in the host origin's `localStorage` (`pdt:open`). The iframe asks for
  `pdt:toggle` (toggle button) and `pdt:open` (a tab was picked); the loader answers
  with `pdt:state`. Both sides check `event.origin` and `event.source`. Later phases add
  `phx:*` window events (client event log) and host socket RTT through
  `window.liveSocket.getSocket().ping/1` when it exists, both read only. Page
  correlation, including live navigation, happens server side (ADR 02), so the
  toolbar keeps working when the loader cannot reach `window.liveSocket`.
- **Panel JS**: `panel.js` connects the panel through the host's LiveView socket (path
  from the layout's `data-socket-path`, CSRF token from the meta tag) and runs the
  `postMessage` side of the bridge.
- **Panel route**: there is no router integration (ADR 01). The plug answers
  `GET <path>/panel?sid=...` itself with `Phoenix.LiveView.Controller.live_render/3`
  (other methods get a 405), passing the sid in the signed LiveView session, with the
  `PhoenixDevToolbar.Layouts.root/1` root layout. The layout loads only `panel.css` and
  `panel.js`, at URLs relative to the panel route, and passes the plug's
  `:live_socket_path` (default `"/live"`) to `panel.js`, which connects through the
  host's LiveView socket. The plug runs before the host's `Plug.Session` in a generated
  endpoint, so the dead render never touches the cookie session (LiveView treats an
  unfetched session as empty). The socket connection does: LiveView refuses to join when
  the CSRF token does not match the host's session cookie, and a token minted by our
  layout never can. `panel.js` therefore sends the host page's CSRF meta token (the
  iframe is same origin; read only), falling back to its own for hosts without one.
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
  seqs already shown. Lists are LiveView streams capped at 500 rows; the summary bar
  (status and duration, query count and database time, router errors) is folded
  incrementally (`PhoenixDevToolbar.Summary`). Tabs: Ecto, Request. An invalid or
  expired sid, or the Store restarting, shows an explanation, not an error.
- Collapsed by default to the header bar (status, query count and time, errors);
  the open state persists in `localStorage` of the host origin.

## Consequences

- Full CSS/JS isolation, no conflicts with host Tailwind, DaisyUI, hooks or `morphdom`.
- Costs one extra WebSocket connection per page in dev, acceptable for a dev tool.
- The panel cannot inspect the host DOM directly; anything DOM related goes through the loader.

## Open limits

- Strict CSP without a nonce (or `frame-src` restrictions) blocks the toolbar; we log a hint.
- Pages that are not HTML responses from Plug (static files) get no toolbar.
