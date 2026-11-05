// phoenix_dev_toolbar panel (ADR 04): runs inside the iframe only.
// Connects PhoenixDevToolbar.PanelLive through the host's LiveView socket and
// talks to the loader in the parent page with origin-checked postMessage.

import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const script =
  document.currentScript || document.querySelector("script[data-socket-path]")

const metaToken = (doc) => {
  const meta = doc.querySelector("meta[name='csrf-token']")
  return meta && meta.getAttribute("content")
}

// The LiveView socket only accepts a CSRF token that matches the host's session
// cookie. Our panel is rendered before the host's session plug runs, so its own
// token cannot match: use the host page's token (same origin, read only), and
// fall back to ours for hosts without one.
const csrfToken = () => {
  try {
    return metaToken(window.parent.document) || metaToken(document)
  } catch (_error) {
    return metaToken(document)
  }
}

const toParent = (type) => {
  if (window.parent !== window) {
    window.parent.postMessage({type: "pdt:" + type}, window.location.origin)
  }
}

const setOpen = (open) => document.documentElement.classList.toggle("pdt-open", open)

window.addEventListener("message", (event) => {
  if (event.origin !== window.location.origin || event.source !== window.parent) return
  if (event.data && event.data.type === "pdt:state") setOpen(Boolean(event.data.open))
})

// The toggle button collapses or expands; picking a tab always expands.
document.addEventListener("click", (event) => {
  if (event.target.closest("[data-pdt-toggle]")) toParent("toggle")
  else if (event.target.closest("[role='tab']")) toParent("open")
})

// A function, so reconnects pick up the host's current token.
const liveSocket = new LiveSocket(script.dataset.socketPath, Socket, {
  params: () => ({_csrf_token: csrfToken()}),
})

liveSocket.connect()
