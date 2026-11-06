// phoenix_dev_toolbar panel (ADR 04): runs inside the iframe only.
// Connects PhoenixDevToolbar.PanelLive through the host's LiveView socket and
// talks to the loader in the parent page with origin-checked postMessage.
//
// Phoenix and LiveView are not bundled: the layout loads the host's own
// installed clients first (window.Phoenix, window.LiveView), so the client
// always matches the host's server version.

import {parse, record, tripped} from "./reloads.mjs"
import {countWrapped} from "./summary.mjs"

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
    // The callback form: a push while disconnected is dropped, not rejected
    // (reconnected() re-sends the state).
    panelHook.pushEvent("pdt:visibility", {open, visible: document.visibilityState === "visible"}, () => {})
  }
}

const setOpen = (next) => {
  open = next
  document.documentElement.classList.toggle("pdt-open", open)
  pushVisibility()
}

// Client events from the loader wait (at most CLIENT_BUFFER) until the hook joins.
const CLIENT_BUFFER = 50
let clientBuffer = []

const pushClient = (payload) => {
  if (panelHook) panelHook.pushEvent("pdt:client", payload, () => {})
  else if (clientBuffer.length < CLIENT_BUFFER) clientBuffer.push(payload)
}

window.addEventListener("message", (event) => {
  if (event.origin !== window.location.origin || event.source !== window.parent) return
  const data = event.data
  if (data && data.type === "pdt:state") setOpen(Boolean(data.open))
  if (data && data.type === "pdt:client") pushClient({event: data.event, dropped: data.dropped})
})

document.addEventListener("visibilitychange", pushVisibility)

// On #pdt-bridge: reports visibility on join and after reconnects, and
// forwards client events.
const PdtPanel = {
  mounted() {
    forgetLoads()
    panelHook = this
    pushVisibility()
    const pending = clientBuffer
    clientBuffer = []
    pending.forEach(pushClient)
  },
  reconnected() {
    pushVisibility()
  },
  destroyed() {
    if (panelHook === this) panelHook = null
  },
}

// On #pdt-summary-more (phx-update="ignore", so its text and hidden state are
// ours): counts the badges that do not fit the collapsed bar. Clicking it opens
// the panel, where the summary shows every badge.
const PdtSummaryMore = {
  mounted() {
    this.summary = document.getElementById("pdt-summary")
    this.count = () => {
      // Open, the summary is as tall as it needs: nothing is hidden. Toggling
      // resizes it, so the observer recounts.
      const hidden = open ? 0 : countWrapped([...this.summary.children].map((badge) => badge.offsetTop))
      this.el.hidden = hidden === 0
      this.el.textContent = "+" + hidden
    }
    this.resize = new ResizeObserver(this.count)
    this.resize.observe(this.summary)
    this.mutation = new MutationObserver(this.count)
    this.mutation.observe(this.summary, {childList: true, subtree: true, characterData: true})
    this.count()
  },
  destroyed() {
    this.resize.disconnect()
    this.mutation.disconnect()
  },
}

// The toggle button collapses or expands, hide shrinks the toolbar to a corner
// pill, and picking a tab always expands.
document.addEventListener("click", (event) => {
  if (event.target.closest("[data-pdt-toggle]")) toParent("toggle")
  else if (event.target.closest("[data-pdt-hide]")) toParent("hide")
  else if (event.target.closest("[data-pdt-open]")) toParent("open")
  else if (event.target.closest("[role='tab']")) toParent("open")
})

// A stream row the server re-renders (an EXPLAIN result) is re-inserted in the
// DOM, which blurs a focused button inside it: keyboard users would lose their
// place. Buttons with data-pdt-keep-focus get it back (or the element its value
// names, when the button itself is gone), unless the user clicked elsewhere.
let pointerTarget = null
document.addEventListener("pointerdown", (event) => { pointerTarget = event.target }, true)

document.addEventListener("focusout", (event) => {
  const el = event.target
  if (event.relatedTarget || !el.matches || !el.matches("[data-pdt-keep-focus]")) return
  if (pointerTarget && !el.contains(pointerTarget)) return
  const fallback = el.dataset.pdtKeepFocus
  requestAnimationFrame(() => {
    if (document.activeElement && document.activeElement !== document.body) return
    const target = el.isConnected ? el : fallback && document.getElementById(fallback)
    if (target) target.focus()
  })
})
document.addEventListener("keydown", () => { pointerTarget = null }, true)

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

// Reload breaker (ADR 04, assets/js/reloads.mjs): this page's panel loads are
// recorded per sid in sessionStorage; a joined panel forgets them. Storage
// blocked: no breaker, never an error.
const loadsKey = "pdt:loads:" + (new URLSearchParams(window.location.search).get("sid") || "")

const storage = () => {
  try {
    return window.sessionStorage
  } catch (_error) {
    return null
  }
}

const recordLoad = () => {
  try {
    const loads = record(parse(storage().getItem(loadsKey)), Date.now())
    storage().setItem(loadsKey, JSON.stringify(loads))
    return loads
  } catch (_error) {
    return []
  }
}

function forgetLoads() {
  try {
    storage().removeItem(loadsKey)
  } catch (_error) {
    // Storage blocked: nothing was recorded.
  }
}

// In the header, so it shows in the collapsed bar too.
const showStalled = () => {
  const notice = document.createElement("div")
  notice.id = "pdt-stalled"
  notice.className = "pdt-stalled"
  notice.setAttribute("role", "alert")
  notice.title =
    "The panel was refused several times in a row and stopped retrying, instead of reloading without end."
  notice.textContent = "The toolbar cannot connect to this page. "

  const retry = document.createElement("button")
  retry.type = "button"
  retry.id = "pdt-stalled-retry"
  retry.className = "pdt-button pdt-button--small"
  retry.textContent = "Retry"
  retry.addEventListener("click", () => {
    forgetLoads()
    window.location.reload()
  })

  notice.appendChild(retry)
  const logo = document.querySelector(".pdt-logo")
  if (logo) logo.after(notice)
  else document.body.prepend(notice)
}

// A function, so reconnects pick up the host's current token.
const liveSocket = new LiveSocket(script.dataset.socketPath, Socket, {
  params: () => ({_csrf_token: csrfToken()}),
  hooks: {PdtPanel, PdtSummaryMore},
})

if (tripped(recordLoad())) showStalled()
else liveSocket.connect()
