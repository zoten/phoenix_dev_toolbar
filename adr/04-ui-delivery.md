# ADR 04: UI Delivery: Isolated Iframe LiveView and Loader

**Status:** Accepted  
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
- **Assets**: the plug serves a whitelist (`loader.js`, `panel.js`, `panel.css`) under
  `<path>/assets/` from `priv/static` (prebuilt with esbuild, committed to the package)
  and halts; anything else, or a missing file, is a 404. The host's asset pipeline is
  never involved.
- **Robustness**: `:path` must be absolute and below the root (raises in `init/1`); while
  the Store restarts every request is served untracked.
- **Loader** (plain JS, about 3 KB): creates a fixed, collapsible container with an
  `<iframe>` pointing to the router-mounted panel (`/__pdt/panel?sid=...`). It is
  read-only towards the host: it listens to `phx:*` window events (client event log),
  measures host socket RTT with `window.liveSocket.getSocket().ping(cb)` (public API of
  `LiveSocket` and `Phoenix.Socket`) when `window.liveSocket` exists, and forwards
  everything to the iframe with `postMessage` (origin checked both ways). Page
  correlation, including live navigation, happens server side (ADR 02), so the
  toolbar keeps working when the loader cannot reach `window.liveSocket`.
- **Panel**: `PhoenixDevToolbar.PanelLive`, mounted by the `dev_toolbar/1` router macro in
  its own `live_session`, with its own root layout, its own LiveSocket and its own CSS.
  It reads events from the Store, subscribes via the Registry, and renders plugins' panels.
- Collapsed by default to a small badge bar (query count, slowest callback, warnings);
  open/closed state and size persist in `localStorage` of the host origin.

## Consequences

- Full CSS/JS isolation, no conflicts with host Tailwind, DaisyUI, hooks or `morphdom`.
- Costs one extra WebSocket connection per page in dev, acceptable for a dev tool.
- The panel cannot inspect the host DOM directly; anything DOM related goes through the loader.

## Open limits

- Strict CSP without a nonce (or `frame-src` restrictions) blocks the toolbar; we log a hint.
- Pages that are not HTML responses from Plug (static files) get no toolbar.
