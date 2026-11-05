// phoenix_dev_toolbar panel (ADR 04): runs inside the iframe only.
// Connects PhoenixDevToolbar.PanelLive through the host's LiveView socket and
// talks to the loader in the parent page with origin-checked postMessage.
//
// Phoenix and LiveView are not bundled: the layout loads the host's own
// installed clients first (window.Phoenix, window.LiveView), so the client
// always matches the host's server version.

const {Socket} = window.Phoenix
const {LiveSocket} = window.LiveView

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

// Whether the panel is worth refreshing: expanded by the loader and the browser
// tab visible. PanelLive polls the component tree only then (ADR 07).
let open = false
let panelHook = null

const pushVisibility = () => {
  if (panelHook) {
    panelHook.pushEvent("pdt:visibility", {open, visible: document.visibilityState === "visible"})
  }
}

const setOpen = (next) => {
  open = next
  document.documentElement.classList.toggle("pdt-open", open)
  pushVisibility()
}

window.addEventListener("message", (event) => {
  if (event.origin !== window.location.origin || event.source !== window.parent) return
  if (event.data && event.data.type === "pdt:state") setOpen(Boolean(event.data.open))
})

document.addEventListener("visibilitychange", pushVisibility)

// On #pdt-panel: reports visibility on join and after reconnects.
const PdtPanel = {
  mounted() {
    panelHook = this
    pushVisibility()
  },
  reconnected() {
    pushVisibility()
  },
  destroyed() {
    if (panelHook === this) panelHook = null
  },
}

// The toggle button collapses or expands, hide shrinks the toolbar to a corner
// pill, and picking a tab always expands.
document.addEventListener("click", (event) => {
  if (event.target.closest("[data-pdt-toggle]")) toParent("toggle")
  else if (event.target.closest("[data-pdt-hide]")) toParent("hide")
  else if (event.target.closest("[role='tab']")) toParent("open")
})

// WAI-ARIA tabs: arrow keys move between tabs and select them.
document.addEventListener("keydown", (event) => {
  const tab = event.target.closest("[role='tab']")
  if (!tab || !["ArrowLeft", "ArrowRight"].includes(event.key)) return

  const tabs = [...tab.closest("[role='tablist']").querySelectorAll("[role='tab']")]
  const step = event.key === "ArrowRight" ? 1 : -1
  const next = tabs[(tabs.indexOf(tab) + step + tabs.length) % tabs.length]
  event.preventDefault()
  next.focus()
  next.click()
})

// A function, so reconnects pick up the host's current token.
const liveSocket = new LiveSocket(script.dataset.socketPath, Socket, {
  params: () => ({_csrf_token: csrfToken()}),
  hooks: {PdtPanel},
})

liveSocket.connect()
