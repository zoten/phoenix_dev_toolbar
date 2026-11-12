// phoenix_dev_toolbar loader (ADR 04).
//
// Injected by PhoenixDevToolbar.Plug before </body>. It only adds one element
// to the host page: a shadow-DOM host holding the panel iframe (and, when the
// toolbar is hidden, a corner pill), so host CSS cannot reach the toolbar and
// the toolbar's CSS cannot reach the host. It is read-only towards the host
// page and never touches window.liveSocket's state. Its one write to a host
// element: docked left or right, an inline padding on <html> makes room for
// the panel, restored when the dock changes or the page opts out of reserving
// space (data-pdt-reserve="false", or the dock menu's toggle).
//
// Element inspector (ADR 16): only while armed by the panel (pdt:pick) the
// loader holds capture phase listeners on the document; the click that picks
// an element is swallowed, never reaching host handlers. The outline lives in
// our shadow root. Disarming removes every listener and the outline.
//
// Client event log (ADR 07): passive listeners on LiveView's own window events
// forward a sanitized copy to the panel through the same origin checked
// postMessage bridge, rate limited and buffered until the panel loads.

import {BUFFER, EVENTS, PER_SECOND, createLimiter, createQueue, sanitize} from "./client_events.mjs"
import {
  DOCKS,
  clampSize,
  defaultSize,
  maxSize,
  minSize,
  parseLayout,
  reservedSize,
  reserving,
  serializeLayout,
  sideDock,
  sizeFromPointer,
  THEMES,
} from "./layout.mjs"
import {outlineBox, resolve} from "./inspect.mjs"
import {label, parseShortcut, triggered} from "./shortcut.mjs"

const STORAGE_KEY = "pdt:state"
const LEGACY_KEY = "pdt:open"
const LAYOUT_KEY = "pdt:layout"
const STATES = ["open", "collapsed", "hidden"]
const KEY_STEP = 16
const KEY_STEP_LARGE = 64
// The arrow that grows the panel, per dock: away from the docked edge.
const GROW_KEYS = {bottom: "ArrowUp", top: "ArrowDown", left: "ArrowRight", right: "ArrowLeft"}
const SHRINK_KEYS = {bottom: "ArrowDown", top: "ArrowUp", left: "ArrowLeft", right: "ArrowRight"}
const MESSAGE_PREFIX = "pdt:"
const CORNERS = ["bottom-left", "top-right", "top-left"]

const script =
  document.currentScript || document.querySelector("script[data-pdt-sid]")

const readState = () => {
  try {
    const stored = window.localStorage.getItem(STORAGE_KEY)
    if (STATES.includes(stored)) return stored
    return window.localStorage.getItem(LEGACY_KEY) === "1" ? "open" : "collapsed"
  } catch (_error) {
    return "collapsed"
  }
}

const writeState = (state) => {
  try {
    window.localStorage.setItem(STORAGE_KEY, state)
    window.localStorage.removeItem(LEGACY_KEY)
  } catch (_error) {
    // Storage may be disabled: the state just will not persist.
  }
}

const readLayout = () => {
  try {
    return parseLayout(window.localStorage.getItem(LAYOUT_KEY))
  } catch (_error) {
    return parseLayout(null)
  }
}

const writeLayout = (layout) => {
  try {
    window.localStorage.setItem(LAYOUT_KEY, serializeLayout(layout))
  } catch (_error) {
    // Storage may be disabled: the size just will not persist.
  }
}

// --pdt-extent is the frame's size across its dock: 34px collapsed, the panel
// size open. Edge docks size the height, side docks the width.
const STYLE = `
  :host { all: initial; }
  .frame {
    position: fixed; z-index: 2147483000; border: 0; margin: 0; padding: 0;
    background: transparent; color-scheme: normal;
  }
  .frame.dock-bottom, .frame.dock-top {
    left: 0; right: 0; width: 100%; height: var(--pdt-extent);
    transition: height 120ms ease-out;
  }
  .frame.dock-bottom { bottom: 0; box-shadow: 0 -1px 0 rgba(0, 0, 0, .25), 0 -4px 16px rgba(0, 0, 0, .12); }
  .frame.dock-top { top: 0; box-shadow: 0 1px 0 rgba(0, 0, 0, .25), 0 4px 16px rgba(0, 0, 0, .12); }
  .frame.dock-left, .frame.dock-right {
    top: 0; bottom: 0; height: 100%; width: var(--pdt-extent);
    transition: width 120ms ease-out;
  }
  .frame.dock-left { left: 0; box-shadow: 1px 0 0 rgba(0, 0, 0, .25), 4px 0 16px rgba(0, 0, 0, .12); }
  .frame.dock-right { right: 0; box-shadow: -1px 0 0 rgba(0, 0, 0, .25), -4px 0 16px rgba(0, 0, 0, .12); }
  .frame.hidden { display: none; }
  .frame.dragging { pointer-events: none; transition: none; }
  .handle {
    position: fixed; z-index: 2147483001; display: none; touch-action: none; outline: none;
  }
  .handle.dock-bottom, .handle.dock-top { left: 0; right: 0; height: 12px; cursor: ns-resize; }
  .handle.dock-bottom { bottom: calc(var(--pdt-extent) - 2px); }
  .handle.dock-top { top: calc(var(--pdt-extent) - 2px); }
  .handle.dock-left, .handle.dock-right { top: 0; bottom: 0; width: 12px; cursor: ew-resize; }
  .handle.dock-left { left: calc(var(--pdt-extent) - 2px); }
  .handle.dock-right { right: calc(var(--pdt-extent) - 2px); }
  .handle::after {
    content: ""; position: absolute; left: 50%; top: 50%; width: 36px; height: 4px;
    transform: translate(-50%, -50%); border-radius: 2px; background: #fd4f00; opacity: 0;
    transition: opacity 120ms ease;
  }
  .handle.dock-bottom::after { top: auto; bottom: 0; transform: translateX(-50%); }
  .handle.dock-top::after { top: 0; transform: translateX(-50%); }
  .handle.dock-left::after, .handle.dock-right::after { width: 4px; height: 36px; }
  .handle.dock-left::after { left: 0; transform: translateY(-50%); }
  .handle.dock-right::after { left: auto; right: 0; transform: translateY(-50%); }
  .handle:hover::after, .handle:focus-visible::after, .handle.dragging::after { opacity: 1; }
  .handle.visible { display: block; }
  .pick-box {
    position: fixed; z-index: 2147482999; pointer-events: none; box-sizing: border-box;
    border: 2px solid #fd4f00; background: rgba(253, 79, 0, .12); border-radius: 2px;
  }
  .pick-label {
    position: fixed; z-index: 2147482999; pointer-events: none; max-width: 60vw;
    padding: 2px 6px; border-radius: 3px; background: #1f2330; color: #fff;
    font: 600 11px/16px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .pill {
    position: fixed; right: 12px; bottom: 12px; z-index: 2147483000;
    display: none; align-items: center; gap: 6px;
    height: 28px; padding: 0 12px; border: 0; border-radius: 14px;
    background: #1f2330; color: #fd4f00; cursor: pointer;
    font: 600 12px/28px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    box-shadow: 0 2px 10px rgba(0, 0, 0, .3);
    transition: transform 120ms ease;
  }
  .pill.corner-bottom-left { right: auto; left: 12px; }
  .pill.corner-top-right { bottom: auto; top: 12px; }
  .pill.corner-top-left { right: auto; bottom: auto; left: 12px; top: 12px; }
  .pill:hover { transform: translateY(-1px); }
  .pill:focus-visible { outline: 2px solid #fd4f00; outline-offset: 2px; }
  .pill.visible { display: inline-flex; }
  @media (prefers-reduced-motion: reduce) { .frame, .pill, .handle::after { transition: none; } }
`

// Docked left or right, the page makes room through an inline padding on
// <html>: the host's own inline value is kept and put back when the toolbar
// stops reserving that side. Our padding adds to the host's computed one.
const createSidePadding = () => {
  const html = document.documentElement
  const original = Object.fromEntries(
    ["padding-left", "padding-right"].map((prop) => [
      prop,
      {value: html.style.getPropertyValue(prop), priority: html.style.getPropertyPriority(prop)},
    ]),
  )
  const restore = (prop) => html.style.setProperty(prop, original[prop].value, original[prop].priority)

  return (side, px) => {
    ;["padding-left", "padding-right"].forEach((prop) => {
      restore(prop)
      if (prop !== `padding-${side}` || px === 0) return
      const base = window.getComputedStyle(html).getPropertyValue(prop) || "0px"
      html.style.setProperty(prop, `calc(${base} + ${px}px)`, "important")
    })
  }
}

// The one element the loader adds to the page: its presence is the "mounted" mark.
const HOST_ID = "phoenix-dev-toolbar"

const mount = () => {
  const {pdtSid: sid, pdtPath: path} = script.dataset
  if (!sid || !path || document.getElementById(HOST_ID)) return

  const host = document.createElement("div")
  host.id = HOST_ID
  host.setAttribute("data-phx-update", "ignore")
  // Inline so host page rules cannot reach it. Its height is the space the bar
  // reserves in the page flow, so the page scrolls its end above the bar.
  host.style.cssText = "display:block;margin:0;padding:0;border:0;height:0"
  const root = host.attachShadow({mode: "open"})

  const style = document.createElement("style")
  style.textContent = STYLE
  // A strict style-src needs the nonce of the page's CSP; the injected script
  // tag carries it (the `nonce` property survives parsing, the attribute does not).
  const nonce = script.nonce || script.getAttribute("nonce")
  if (nonce) style.setAttribute("nonce", nonce)

  const frame = document.createElement("iframe")
  frame.className = "frame"
  frame.title = "Phoenix dev toolbar"
  frame.src = `${path}/panel?sid=${encodeURIComponent(sid)}`

  const pill = document.createElement("button")
  pill.className = "pill"
  pill.type = "button"
  pill.textContent = "dev toolbar"
  // Bottom right is the default (no class); unknown values are ignored.
  const corner = script.dataset.pdtPill
  if (CORNERS.includes(corner)) pill.classList.add(`corner-${corner}`)
  // Opt in toggle shortcut: only a canonical, parsable value counts.
  const shortcutSource = script.dataset.pdtShortcut
  const shortcut = parseShortcut(shortcutSource)
  pill.title = shortcut ? `Show the dev toolbar (${label(shortcutSource)})` : "Show the dev toolbar"

  const handle = document.createElement("div")
  handle.className = "handle"
  handle.tabIndex = 0
  handle.title = "Drag to resize, double click to reset"
  handle.setAttribute("role", "separator")
  handle.setAttribute("aria-label", "Resize the dev toolbar")

  root.append(style, frame, handle, pill)

  let state = readState()
  const layout = readLayout()
  const reserveDefault = script.dataset.pdtReserve
  let dock = layout.dock
  const sidePadding = createSidePadding()
  const viewport = () => (sideDock(dock) ? window.innerWidth : window.innerHeight)
  // `layout.sizes` holds the user's size per dock; `size` is the current dock's,
  // clamped to the viewport, so shrinking the window and growing it back
  // restores the user's size.
  let size = clampSize(layout.sizes[dock], viewport(), dock)
  const post = (type, payload = {}) =>
    frame.contentWindow &&
    frame.contentWindow.postMessage({type: MESSAGE_PREFIX + type, ...payload}, window.location.origin)
  const postState = () => post("state", {open: state === "open", dock, reserve: reserving(layout, reserveDefault), shortcut: shortcut ? shortcutSource : null, theme: layout.theme})
  const saveLayout = () => writeLayout({dock, sizes: layout.sizes, reserve: layout.reserve, theme: layout.theme})

  // Docked at the top, the host div leads <body> so its height pushes the page
  // down; otherwise it closes <body>, so the page scrolls its end above the bar.
  const placeHost = () => {
    if (dock === "top" && document.body.firstChild !== host) document.body.prepend(host)
    if (dock !== "top" && document.body.lastChild !== host) document.body.append(host)
  }

  const applySize = () => {
    const reserved = reservedSize(state, size, reserving(layout, reserveDefault))
    host.style.setProperty("--pdt-extent", `${state === "open" ? size : reservedSize("collapsed", size)}px`)
    host.style.height = sideDock(dock) ? "0" : `${reserved}px`
    sidePadding(dock, sideDock(dock) ? reserved : 0)
    handle.setAttribute("aria-valuemin", String(minSize(dock)))
    handle.setAttribute("aria-valuemax", String(maxSize(viewport(), dock)))
    handle.setAttribute("aria-valuenow", String(size))
    handle.setAttribute("aria-valuetext", `${size} pixels`)
  }

  const resize = (next, persist) => {
    size = clampSize(next, viewport(), dock)
    applySize()
    if (!persist) return
    layout.sizes[dock] = size
    saveLayout()
  }

  const setDock = (next) => {
    dock = next
    ;[frame, handle].forEach((el) => {
      DOCKS.forEach((name) => el.classList.toggle(`dock-${name}`, name === dock))
    })
    handle.setAttribute("aria-orientation", sideDock(dock) ? "vertical" : "horizontal")
    placeHost()
    size = clampSize(layout.sizes[dock], viewport(), dock)
    applySize()
  }

  const setState = (next) => {
    state = next
    frame.classList.toggle("hidden", state === "hidden")
    handle.classList.toggle("visible", state === "open")
    pill.classList.toggle("visible", state === "hidden")
    if (state !== "open") clearHighlight()
    applySize()
    writeState(state)
    postState()
  }

  const limiter = createLimiter(PER_SECOND)
  const dropped = () => limiter.dropped() + queue.dropped()
  const queue = createQueue(BUFFER, (event) => post("client", {event, dropped: dropped()}))

  // Drops are reported with the next event, or on their own a second later
  // when no event follows (the end of a burst).
  let dropTimer = null
  const reportDrops = () => {
    if (dropTimer) return
    dropTimer = setTimeout(() => {
      dropTimer = null
      post("client", {event: null, dropped: dropped()})
    }, 1000)
  }

  EVENTS.forEach((name) =>
    window.addEventListener(
      name,
      (event) => {
        // Runs inside the host's event dispatch: never throw from here.
        try {
          const now = Date.now()
          if (limiter.allow(now)) queue.push(sanitize(name, event.detail, now))
          else reportDrops()
        } catch (_error) {
          // Dropped silently: the toolbar must not show up in host error tracking.
        }
      },
      {passive: true},
    ),
  )

  // Dragging: the iframe ignores pointer events meanwhile, or it would swallow
  // the moves. Moves are batched to one resize per frame.
  let drag = null
  const endDrag = () => {
    if (!drag) return
    if (drag.frame) cancelAnimationFrame(drag.frame)
    drag = null
    frame.classList.remove("dragging")
    handle.classList.remove("dragging")
    resize(size, true)
  }

  handle.addEventListener("pointerdown", (event) => {
    if (event.button !== 0) return
    event.preventDefault()
    handle.setPointerCapture(event.pointerId)
    drag = {frame: null, x: event.clientX, y: event.clientY}
    frame.classList.add("dragging")
    handle.classList.add("dragging")
  })
  handle.addEventListener("pointermove", (event) => {
    if (!drag) return
    drag.x = event.clientX
    drag.y = event.clientY
    if (drag.frame) return
    drag.frame = requestAnimationFrame(() => {
      if (!drag) return
      drag.frame = null
      resize(sizeFromPointer(dock, drag.x, drag.y, window.innerWidth, window.innerHeight), false)
    })
  })
  handle.addEventListener("pointerup", endDrag)
  handle.addEventListener("pointercancel", endDrag)
  handle.addEventListener("lostpointercapture", endDrag)
  handle.addEventListener("dblclick", () => resize(defaultSize(viewport(), dock), true))
  handle.addEventListener("keydown", (event) => {
    const step = event.shiftKey ? KEY_STEP_LARGE : KEY_STEP
    const next = {
      [GROW_KEYS[dock]]: size + step,
      [SHRINK_KEYS[dock]]: size - step,
      Home: defaultSize(viewport(), dock),
    }[event.key]
    if (next === undefined) return
    event.preventDefault()
    resize(next, true)
  })

  let resizeFrame = null
  window.addEventListener(
    "resize",
    () => {
      if (resizeFrame) return
      resizeFrame = requestAnimationFrame(() => {
        resizeFrame = null
        resize(layout.sizes[dock], false)
      })
    },
    {passive: true},
  )

  // Runs inside the host's keydown dispatch: never throws, and only a match
  // (not typing, not a repeat) is claimed with preventDefault. Hidden comes
  // back collapsed; otherwise open and collapsed swap.
  if (shortcut) {
    window.addEventListener("keydown", (event) => {
      try {
        if (!triggered(shortcut, event)) return
        event.preventDefault()
        setState(state === "collapsed" ? "open" : "collapsed")
      } catch (_error) {
        // Dropped silently: the toolbar must not show up in host error tracking.
      }
    })
  }

  pill.addEventListener("click", () => {
    setState("collapsed")
    // The frame is shown again: the panel moves focus on to its toggle.
    frame.focus()
    post("focus")
  })
  frame.addEventListener("load", () => {
    postState()
    queue.ready()
  })

  // Element inspector: one outline box and label in the shadow root.
  const HIGHLIGHT_MS = 3000
  let box = null
  let tip = null
  let armed = false
  let hoverTarget = null
  let hoverFrame = false
  let highlightTimer = null
  const place = (element, text) => {
    const rect = outlineBox(element)
    if (!box) {
      box = document.createElement("div")
      box.className = "pick-box"
      tip = document.createElement("div")
      tip.className = "pick-label"
      root.append(box, tip)
    }
    box.style.cssText = `left:${rect.left}px;top:${rect.top}px;width:${rect.width}px;height:${rect.height}px`
    tip.textContent = text
    tip.style.cssText = `left:${Math.max(0, rect.left)}px;top:${rect.top >= 20 ? rect.top - 20 : rect.top + rect.height + 2}px`
  }
  const clearBox = () => {
    if (box) box.remove()
    if (tip) tip.remove()
    box = tip = null
  }
  const ours = (target) => !target || host === target || host.contains(target)
  const describe = (element) => {
    const {tag, frames} = resolve(element)
    return frames.length > 0 ? `${tag} in ${frames[0].name}` : tag
  }

  const clearHighlight = () => {
    if (highlightTimer !== null) window.clearTimeout(highlightTimer)
    highlightTimer = null
    window.removeEventListener("scroll", clearHighlight, true)
    if (!armed) clearBox()
  }

  // Cids are per LiveView: skip matches that belong to a nested LiveView.
  const component = (view, cid) =>
    Array.from(view.querySelectorAll(`[data-phx-component="${cid}"]`)).find((el) => el.closest("[data-phx-session]") === view)

  const highlight = (data) => {
    clearHighlight()
    if (armed || typeof data.root !== "string") return
    const view = document.getElementById(data.root)
    if (!view || ours(view)) return
    const element = Number.isInteger(data.cid) ? component(view, data.cid) : view
    if (!element) return
    place(element, Number.isInteger(data.cid) ? `component ${data.cid}` : `#${data.root}`)
    window.addEventListener("scroll", clearHighlight, true)
    highlightTimer = window.setTimeout(clearHighlight, HIGHLIGHT_MS)
  }

  const onMove = (event) => {
    try {
      hoverTarget = event.target
      if (hoverFrame) return
      hoverFrame = true
      requestAnimationFrame(() => {
        hoverFrame = false
        try {
          if (!armed) return
          if (ours(hoverTarget)) clearBox()
          else place(hoverTarget, describe(hoverTarget))
        } catch (_error) {
          // Dropped silently: the toolbar must not show up in host error tracking.
        }
      })
    } catch (_error) {
      // Same: never throw into the host's event dispatch.
    }
  }

  const onPick = (event) => {
    try {
      if (ours(event.target)) return
      event.preventDefault()
      event.stopPropagation()
      const inspected = resolve(event.target)
      disarm()
      post("inspect", {inspected})
      setState("open")
    } catch (_error) {
      // Dropped silently: the toolbar must not show up in host error tracking.
    }
  }

  const onKey = (event) => {
    try {
      if (event.key !== "Escape") return
      event.preventDefault()
      event.stopPropagation()
      disarm()
    } catch (_error) {
      // Same as above.
    }
  }

  // Pointer and mouse presses would focus an input or start host drag logic.
  const swallow = (event) => {
    try {
      if (ours(event.target)) return
      event.preventDefault()
      event.stopPropagation()
    } catch (_error) {
      // Same as above.
    }
  }

  const listeners = [
    ["pointerdown", swallow],
    ["mousedown", swallow],
    ["pointerup", swallow],
    ["mouseup", swallow],
    ["pointermove", onMove],
    ["click", onPick],
    ["keydown", onKey],
  ]

  function disarm() {
    if (!armed) return
    armed = false
    hoverTarget = null
    listeners.forEach(([type, fun]) => document.removeEventListener(type, fun, true))
    clearBox()
    post("picking", {armed: false})
  }

  // A reloaded panel starts not picking: keep the loader in sync.
  frame.addEventListener("load", disarm)

  const arm = () => {
    clearHighlight()
    armed = true
    listeners.forEach(([type, fun]) => document.addEventListener(type, fun, true))
    post("picking", {armed: true})
  }

  // Only our own iframe, on our own origin, may drive the container.
  window.addEventListener("message", (event) => {
    if (event.origin !== window.location.origin || event.source !== frame.contentWindow) return
    const type = event.data && event.data.type

    if (type === "pdt:toggle") setState(state === "open" ? "collapsed" : "open")
    if (type === "pdt:open") setState("open")
    if (type === "pdt:close") setState("collapsed")
    if (type === "pdt:hide") {
      // Focus in the frame would be lost with it: hand it to the pill.
      const framed = root.activeElement === frame
      setState("hidden")
      if (framed) pill.focus()
    }
    if (type === "pdt:pick") {
      if (armed) disarm()
      else arm()
    }
    if (type === "pdt:highlight") highlight(event.data)
    if (type === "pdt:dock" && DOCKS.includes(event.data.dock)) {
      setDock(event.data.dock)
      saveLayout()
      postState()
    }
    if (type === "pdt:theme" && THEMES.includes(event.data.theme)) {
      layout.theme = event.data.theme
      saveLayout()
      postState()
    }
    if (type === "pdt:reserve" && typeof event.data.reserve === "boolean") {
      layout.reserve = event.data.reserve
      applySize()
      saveLayout()
      postState()
    }
  })

  setDock(dock)
  setState(state)
}

// Never inside iframes (including our own panel); `mount` skips a page that
// already has the toolbar, so a twice evaluated script adds nothing.
if (script && window.top === window) {
  if (document.body) {
    mount()
  } else {
    document.addEventListener("DOMContentLoaded", mount, {once: true})
  }
}
