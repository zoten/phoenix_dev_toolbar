# ADR 04: UI Delivery: Isolated Iframe LiveView and Loader

**Status:** Accepted  
**Area:** ui  
**Related:** [ADR 01](./01-zero-prod-footprint-and-installation.md) (install), [ADR 03](./03-event-storage.md) (data source)

## Context

The toolbar must appear on every page without the host editing templates or
`app.js`, must not be styled by the host's CSS (nor style it), and must not
interfere with the host's LiveSocket, DOM patching or CSP.

## Decision

- **Injection**: `PhoenixDevToolbar.Plug` registers a `before_send` callback that, only
  for `text/html` 200 responses that are not chunked and contain `</body>`, inserts a
  single `<script src="/__pdt/assets/loader.js" data-sid="..." defer>` before `</body>`
  (the `Phoenix.LiveReloader` technique). If `conn.assigns[:csp_nonce]` (or a configured
  key) is present it is added as `nonce`.
- **Assets**: the plug serves `/__pdt/assets/*` from `priv/static` (prebuilt with esbuild,
  committed to the package), so the host's asset pipeline is never involved.
- **Loader** (plain JS, about 3 KB): creates a fixed, collapsible container with an
  `<iframe>` pointing to the router-mounted panel (`/__pdt/panel?sid=...`). It is
  read-only towards the host: it reads the main LiveView id, listens to `phx:*` window
  events and `phx:page-loading-stop` (live navigation changes the LiveView), measures
  host socket RTT with `window.liveSocket.socket.ping/1` when available, and forwards
  everything to the iframe with `postMessage` (origin checked both ways).
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
