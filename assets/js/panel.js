// phoenix_dev_toolbar panel (ADR 04): runs inside the iframe only.
// Connects PhoenixDevToolbar.PanelLive through the panel's own socket
// (PhoenixDevToolbar.PanelSocket, no host session or CSRF token involved) and
// talks to the loader in the parent page with origin-checked postMessage.
//
// Phoenix and LiveView are not bundled: the layout loads the host's own
// installed clients first (window.Phoenix, window.LiveView), so the client
// always matches the host's server version.

import {parse, record, stale, tripped} from "./reloads.mjs"
import {createExportCopy} from "./export_copy.mjs"
import {countWrapped} from "./summary.mjs"

const {Socket} = window.Phoenix
const {LiveSocket} = window.LiveView

const script =
  document.currentScript || document.querySelector("script[data-socket-path]")

const toParent = (type, payload = {}) => {
  if (window.parent !== window) {
    window.parent.postMessage({type: "pdt:" + type, ...payload}, window.location.origin)
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
  const toggle = document.getElementById("pdt-toggle")
  if (toggle) toggle.setAttribute("aria-expanded", String(open))
  if (!open) closeDockMenu(false)
  pushVisibility()
}

// Docks (ADR 04): the loader owns the dock and reports it with every state.
// The root gets pdt-dock-<name>, plus pdt-side for left and right.
const DOCKS = ["bottom", "top", "left", "right"]

const setDock = (dock) => {
  if (!DOCKS.includes(dock)) return
  const root = document.documentElement
  DOCKS.forEach((name) => root.classList.toggle("pdt-dock-" + name, name === dock))
  root.classList.toggle("pdt-side", dock === "left" || dock === "right")
  document.querySelectorAll("[data-pdt-dock]").forEach((option) => {
    option.setAttribute("aria-pressed", String(option.dataset.pdtDock === dock))
  })
}

// Whether the page makes room for the toolbar (ADR 04): the loader owns it.
const setReserve = (reserve) => {
  if (typeof reserve !== "boolean") return
  const toggle = document.getElementById("pdt-reserve")
  if (toggle) toggle.setAttribute("aria-pressed", String(reserve))
}

const dockMenu = () => document.getElementById("pdt-dock-menu")
const dockButton = () => document.getElementById("pdt-dock")

function closeDockMenu(refocus) {
  const menu = dockMenu()
  if (!menu || menu.hidden) return
  menu.hidden = true
  dockButton().setAttribute("aria-expanded", "false")
  if (refocus) dockButton().focus()
}

// The menu hangs from the picker's end edge. A narrow panel (side docks) can
// wrap the picker to the start of a row, where that would cross the iframe's
// left edge: hang it from the start edge instead.
const placeDockMenu = (menu) => {
  menu.classList.remove("pdt-dock-menu--start")
  if (menu.getBoundingClientRect().left < 0) menu.classList.add("pdt-dock-menu--start")
}

const toggleDockMenu = () => {
  const menu = dockMenu()
  if (!menu.hidden) return closeDockMenu(false)
  menu.hidden = false
  placeDockMenu(menu)
  dockButton().setAttribute("aria-expanded", "true")
  const current = menu.querySelector("[data-pdt-dock][aria-pressed='true']") || menu.querySelector("[data-pdt-dock]")
  current.focus()
}

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && event.target.closest && event.target.closest("#pdt-dock-picker")) {
    closeDockMenu(true)
  }
})

// Tabbing out of the picker closes the menu (no refocus: focus went elsewhere).
document.addEventListener("focusout", (event) => {
  const picker = event.target.closest && event.target.closest("#pdt-dock-picker")
  if (!picker || !event.relatedTarget || picker.contains(event.relatedTarget)) return
  closeDockMenu(false)
})

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
  if (data && data.type === "pdt:state") {
    setDock(data.dock)
    setReserve(data.reserve)
    setOpen(Boolean(data.open))
  }
  if (data && data.type === "pdt:focus") {
    const toggle = document.getElementById("pdt-toggle")
    if (toggle) toggle.focus()
  }
  if (data && data.type === "pdt:client") pushClient({event: data.event, dropped: data.dropped})
})

document.addEventListener("visibilitychange", pushVisibility)

// Opened in a browser tab of its own (ADR 14), not in the loader's iframe: no
// loader sends pdt:state, so the panel is open at the bottom dock, and CSS
// hides the controls that would talk to a loader (pdt-standalone).
if (window.parent === window) {
  document.documentElement.classList.add("pdt-standalone")
  setDock("bottom")
  setOpen(true)
}

// The live region #pdt-live-status (phx-update="ignore") announces the
// connection; a reconnect message clears itself after `clearAfter` ms.
let statusTimer = null
const say = (text, clearAfter) => {
  const status = document.getElementById("pdt-live-status")
  if (!status) return
  window.clearTimeout(statusTimer)
  status.textContent = text
  if (clearAfter) statusTimer = window.setTimeout(() => { status.textContent = "" }, clearAfter)
}

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
  disconnected() {
    say("Toolbar disconnected: what it shows is frozen until it reconnects")
  },
  reconnected() {
    pushVisibility()
    say("Toolbar reconnected", 3000)
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
      // Collapsed on a side, the strip is sideways (vertical-rl): badges wrap
      // into columns to the left, so the "row" is the column offset.
      const side = document.documentElement.classList.contains("pdt-side")
      const rows = [...this.summary.children].map((badge) => (side ? -badge.offsetLeft : badge.offsetTop))
      const hidden = open ? 0 : countWrapped(rows)
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
// Copy: the tab pushes its JSON export (or an error); export_copy.mjs decides
// what reaches the clipboard and what the result line (#pdt-export-result,
// phx-update="ignore") says. The form carries the page it shows (data-pdt-page).

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
    const result = this.el.querySelector("#pdt-export-result")
    this.copier = createExportCopy({
      clipboard: navigator.clipboard,
      ClipboardItem: typeof ClipboardItem === "undefined" ? undefined : ClipboardItem,
      Blob,
      execCopy,
      setTimeout: (fun, ms) => window.setTimeout(fun, ms),
      clearTimeout: (timer) => window.clearTimeout(timer),
      say: (text) => {
        if (result) result.textContent = text
      },
      warn: (error) => console.warn("[phoenix_dev_toolbar] copy failed:", error),
    })
    this.onClick = (event) => {
      if (!event.target.closest("#pdt-export-copy")) return
      if (this.copier.click()) {
        event.preventDefault()
        event.stopPropagation()
      }
    }
    this.onChange = () => this.copier.changed()
    this.el.addEventListener("click", this.onClick, true)
    this.el.addEventListener("change", this.onChange)
    this.page = this.el.dataset.pdtPage
    this.handleEvent("pdt:export", (data) => this.copier.arrive(data, this.el.dataset.pdtPage))
  },
  updated() {
    if (this.el.dataset.pdtPage === this.page) return
    this.page = this.el.dataset.pdtPage
    this.copier.pageChanged()
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick, true)
    this.el.removeEventListener("change", this.onChange)
    this.copier.destroy()
  },
}

// On #pdt-markdown (ADR 04, 13): "Copy as Markdown". Same clipboard path as
// PdtExport: the click claims the clipboard, the server pushes `pdt:markdown`
// ({text, page} or {error, page}) and export_copy.mjs copies the text as is.
const PdtMarkdown = {
  mounted() {
    const result = this.el.querySelector("#pdt-markdown-result")
    this.copier = createExportCopy({
      clipboard: navigator.clipboard,
      ClipboardItem: typeof ClipboardItem === "undefined" ? undefined : ClipboardItem,
      Blob,
      execCopy,
      fallback: "",
      button: "Copy as Markdown",
      setTimeout: (fun, ms) => window.setTimeout(fun, ms),
      clearTimeout: (timer) => window.clearTimeout(timer),
      // A success fades after a few seconds: the line sits in the header.
      say: (text) => {
        window.clearTimeout(this.fade)
        if (result) result.textContent = text
        if (text === "Copied") this.fade = window.setTimeout(() => result && (result.textContent = ""), 3000)
      },
      warn: (error) => console.warn("[phoenix_dev_toolbar] copy failed:", error),
    })
    this.onClick = (event) => {
      if (!event.target.closest("#pdt-markdown-copy")) return
      if (this.copier.click()) {
        event.preventDefault()
        event.stopPropagation()
      }
    }
    this.el.addEventListener("click", this.onClick, true)
    this.page = this.el.dataset.pdtPage
    this.handleEvent("pdt:markdown", (data) => this.copier.arrive(data, this.el.dataset.pdtPage))
  },
  updated() {
    if (this.el.dataset.pdtPage === this.page) return
    this.page = this.el.dataset.pdtPage
    this.copier.pageChanged()
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick, true)
    window.clearTimeout(this.fade)
    this.copier.destroy()
  },
}

// The toggle button collapses or expands, hide shrinks the toolbar to a corner
// pill, and picking a tab always expands.
document.addEventListener("click", (event) => {
  const dockOption = event.target.closest("[data-pdt-dock]")
  if (!event.target.closest("#pdt-dock-picker")) closeDockMenu(false)

  const reserveToggle = event.target.closest("[data-pdt-reserve]")

  if (event.target.closest("[data-pdt-dock-menu]")) toggleDockMenu()
  else if (reserveToggle) toParent("reserve", {reserve: reserveToggle.getAttribute("aria-pressed") !== "true"})
  else if (dockOption) {
    closeDockMenu(true)
    toParent("dock", {dock: dockOption.dataset.pdtDock})
  } else if (event.target.closest("[data-pdt-toggle]")) toParent("toggle")
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

// WAI-ARIA tabs: arrow keys, Home and End move between tabs and select them.
document.addEventListener("keydown", (event) => {
  const tab = event.target.closest("[role='tab']")
  if (!tab || !["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return

  const tabs = [...tab.closest("[role='tablist']").querySelectorAll("[role='tab']")]
  const step = event.key === "ArrowRight" ? 1 : -1
  const next = {
    Home: tabs[0],
    End: tabs[tabs.length - 1],
  }[event.key] || tabs[(tabs.indexOf(tab) + step + tabs.length) % tabs.length]
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
  hooks: {PdtPanel, PdtSummaryMore, PdtExport, PdtMarkdown},
})

if (tripped(recordLoad())) {
  showStalled("It was refused several times in a row and stopped retrying instead of reloading without end.")
} else {
  liveSocket.connect()
  setTimeout(() => {
    if (!joinedOnce) showStalled("It has not connected yet: its WebSocket may be blocked or refused (the server log says why).")
  }, JOIN_MS)
}
