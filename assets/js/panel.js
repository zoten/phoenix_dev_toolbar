// phoenix_dev_toolbar panel (ADR 04): runs inside the iframe only.
// Connects PhoenixDevToolbar.PanelLive through the panel's own socket
// (PhoenixDevToolbar.PanelSocket, no host session or CSRF token involved) and
// talks to the loader in the parent page with origin-checked postMessage.
//
// Phoenix and LiveView are not bundled: the layout loads the host's own
// installed clients first (window.Phoenix, window.LiveView), so the client
// always matches the host's server version.

import {parse, record, stale, tripped} from "./reloads.mjs"
import {countWrapped} from "./summary.mjs"

const {Socket} = window.Phoenix
const {LiveSocket} = window.LiveView

const script =
  document.currentScript || document.querySelector("script[data-socket-path]")

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
    clearStalled()
    joinedOnce = true
    // From now on a lost connection shows "Disconnected" (assets/css/panel.css).
    document.documentElement.classList.add("pdt-joined")
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

// On #pdt-ecto-export (ADR 08): Download is a plain same-origin link the plug
// answers (a blob: link here is blocked by a host's frame-src in Firefox).
// Copy: the tab pushes its JSON export; the result line (#pdt-export-result,
// phx-update="ignore") is ours. The export arrives after a round trip (and EXPLAINs), too late for
//   the click's user activation. Where ClipboardItem exists (secure contexts:
//   https or localhost), the write starts in the click itself with a promised
//   blob, resolved when the export arrives. Elsewhere (plain http on a LAN IP)
//   there is no Clipboard API: execCommand("copy") on arrival, and when the
//   activation has expired the JSON is held and the next Copy click copies it.
// An export names the page it was built from (the form's data-pdt-page): one
// that no longer matches, because the LiveView joined or the tab navigated
// meanwhile, is dropped, never copied.
const EXPORT_WAIT_MS = 60000
const HELD_MS = 60000

// The pre Clipboard API copy: works without a secure context, within the
// click's user activation only. Focus goes back where it was.
const execCopy = (text) => {
  const focused = document.activeElement
  const area = document.createElement("textarea")
  area.value = text
  area.readOnly = true
  area.setAttribute("aria-hidden", "true")
  area.style.cssText = "position:fixed;top:0;left:-9999px;opacity:0"
  document.body.appendChild(area)
  area.select()
  let copied = false
  try {
    copied = document.execCommand("copy")
  } catch (_error) {
    copied = false
  }
  area.remove()
  if (focused && focused.focus) focused.focus()
  return copied
}

const PdtExport = {
  mounted() {
    this.result = this.el.querySelector("#pdt-export-result")
    this.pending = null
    this.held = null
    this.onClick = (event) => {
      if (!event.target.closest("#pdt-export-copy")) return
      if (this.held) {
        // The held export, copied in this click: no new export.
        event.preventDefault()
        event.stopPropagation()
        const json = this.held.json
        this.drop()
        this.say(execCopy(json) ? "Copied" : "Copy failed: use Download")
      } else {
        this.startCopy()
      }
    }
    // A new choice: the held export no longer matches the form.
    this.onChange = () => this.drop()
    this.el.addEventListener("click", this.onClick, true)
    this.el.addEventListener("change", this.onChange)
    this.page = this.el.dataset.pdtPage
    this.handleEvent("pdt:export", ({payload, page}) => {
      if (page === this.el.dataset.pdtPage) this.copy(JSON.stringify(payload, null, 2))
      else this.pageChanged()
    })
  },
  updated() {
    if (this.el.dataset.pdtPage === this.page) return
    this.page = this.el.dataset.pdtPage
    if (this.held) this.pageChanged()
  },
  pageChanged() {
    this.drop()
    this.changed = true
    if (!this.settle(null)) this.changed = false
    this.say("The page changed: click Copy again")
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick, true)
    this.el.removeEventListener("change", this.onChange)
    this.drop()
    this.settle(null)
  },
  say(text) {
    if (this.result) this.result.textContent = text
  },
  hold(json) {
    this.drop()
    const timer = setTimeout(() => this.drop(), HELD_MS)
    this.held = {json, timer}
    this.say("Export ready: click Copy again")
  },
  drop() {
    if (this.held) clearTimeout(this.held.timer)
    this.held = null
  },
  // In the click: claims the clipboard now, the text comes later.
  startCopy() {
    const clipboard = navigator.clipboard
    if (!clipboard || !clipboard.write || typeof ClipboardItem === "undefined") return
    this.settle(null)
    let resolve, reject
    const text = new Promise((ok, fail) => { resolve = ok; reject = fail })
    const timer = setTimeout(() => this.settle(null), EXPORT_WAIT_MS)
    this.pending = {resolve, reject, timer}
    this.say("Copying…")
    clipboard.write([new ClipboardItem({"text/plain": text})]).then(
      () => this.say("Copied"),
      (error) => this.copyFailed(error),
    )
  },
  // Resolves the pending copy with `json`, or abandons it (null).
  settle(json) {
    const pending = this.pending
    if (!pending) return false
    this.pending = null
    clearTimeout(pending.timer)
    if (json === null) pending.reject(new Error("no export arrived"))
    else pending.resolve(new Blob([json], {type: "text/plain"}))
    return true
  },
  copy(json) {
    if (this.settle(json)) return
    const clipboard = navigator.clipboard
    if (clipboard && clipboard.writeText) {
      clipboard.writeText(json).then(() => this.say("Copied"), (error) => this.copyFailed(error))
    } else if (execCopy(json)) {
      this.say("Copied")
    } else {
      this.hold(json)
    }
  },
  copyFailed(error) {
    // The pending copy was abandoned by pageChanged(): its message stays.
    if (this.changed) {
      this.changed = false
      return
    }
    const why = (error && (error.name || error.message)) || "refused"
    console.warn("[phoenix_dev_toolbar] copy failed:", error)
    this.say("Copy failed (" + why + "): use Download")
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

// Other pages' records past the window are dropped: a page whose panel never
// joins leaves its key behind.
const pruneLoads = (now) => {
  try {
    const keys = []
    for (let i = 0; i < storage().length; i++) keys.push(storage().key(i))

    keys
      .filter((key) => key && key.startsWith("pdt:loads:") && key !== loadsKey)
      .filter((key) => stale(parse(storage().getItem(key)), now))
      .forEach((key) => storage().removeItem(key))
  } catch (_error) {
    // Storage blocked: nothing to prune.
  }
}

const recordLoad = () => {
  try {
    pruneLoads(Date.now())
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

// In the header, so it shows in the collapsed bar too. `why` is read by screen
// readers and shown as a tooltip.
const showStalled = (why) => {
  if (document.getElementById("pdt-stalled")) return
  const notice = document.createElement("div")
  notice.id = "pdt-stalled"
  notice.className = "pdt-stalled"
  notice.setAttribute("role", "alert")
  notice.title = "The toolbar cannot connect to this page. " + why

  // Short, so it fits the collapsed bar; the full reason is the tooltip and
  // what screen readers hear.
  const text = document.createElement("span")
  text.className = "pdt-stalled__text"
  text.textContent = "Cannot connect"
  notice.appendChild(text)

  const reason = document.createElement("span")
  reason.className = "pdt-sr-only"
  reason.textContent = ": the toolbar cannot connect to this page. " + why + " "
  notice.appendChild(reason)

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
  // The tabs have nothing to show: dimmed and out of reach until it joins.
  setTabsInert(true)
}

function clearStalled() {
  const notice = document.getElementById("pdt-stalled")
  if (notice) notice.remove()
  setTabsInert(false)
}

function setTabsInert(inert) {
  document.querySelectorAll(".pdt-tabs").forEach((tabs) => { tabs.inert = inert })
}

// A panel that never joins (the WebSocket itself refused or blocked, for
// example by a proxy) never reloads either: it says so after JOIN_MS, and the
// notice goes away if it joins later.
const JOIN_MS = 8000
let joinedOnce = false

// The panel's own socket at <path>/live: WebSocket only (no long poll
// fallback), no CSRF param (it carries no session).
const liveSocket = new LiveSocket(script.dataset.socketPath, Socket, {
  hooks: {PdtPanel, PdtSummaryMore, PdtExport},
})

if (tripped(recordLoad())) {
  showStalled("It was refused several times in a row and stopped retrying instead of reloading without end.")
} else {
  liveSocket.connect()
  setTimeout(() => {
    if (!joinedOnce) showStalled("It has not connected yet: its WebSocket may be blocked.")
  }, JOIN_MS)
}
