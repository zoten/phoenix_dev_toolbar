// phoenix_dev_toolbar loader (ADR 04).
//
// Injected by PhoenixDevToolbar.Plug before </body>. It only adds one element
// to the host page: a shadow-DOM host holding the panel iframe (and, when the
// toolbar is hidden, a corner pill), so host CSS cannot reach the toolbar and
// the toolbar's CSS cannot reach the host. It is read-only towards the host
// page and never touches window.liveSocket's state.
//
// Client event log (ADR 07): passive listeners on LiveView's own window events
// forward a sanitized copy to the panel through the same origin checked
// postMessage bridge, rate limited and buffered until the panel loads.

import {BUFFER, EVENTS, PER_SECOND, createLimiter, createQueue, sanitize} from "./client_events.mjs"
import {
  COLLAPSED_SIZE,
  MIN_SIZE,
  PAGE_STRIP,
  clampSize,
  defaultSize,
  parseLayout,
  reservedSize,
  serializeLayout,
} from "./layout.mjs"

const STORAGE_KEY = "pdt:state"
const LEGACY_KEY = "pdt:open"
const LAYOUT_KEY = "pdt:layout"
const STATES = ["open", "collapsed", "hidden"]
const KEY_STEP = 16
const KEY_STEP_LARGE = 64
const MESSAGE_PREFIX = "pdt:"

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

const STYLE = `
  :host { all: initial; }
  .frame {
    position: fixed; left: 0; right: 0; bottom: 0; z-index: 2147483000;
    width: 100%; height: ${COLLAPSED_SIZE}px; border: 0; margin: 0; padding: 0;
    box-shadow: 0 -1px 0 rgba(0, 0, 0, .25), 0 -4px 16px rgba(0, 0, 0, .12);
    background: transparent; color-scheme: normal;
    transition: height 120ms ease-out;
  }
  .frame.open { height: var(--pdt-size); }
  .frame.hidden { display: none; }
  .frame.dragging { pointer-events: none; transition: none; }
  .handle {
    position: fixed; left: 0; right: 0; bottom: calc(var(--pdt-size) - 3px);
    z-index: 2147483001; height: 6px; display: none;
    cursor: ns-resize; touch-action: none; outline: none;
  }
  .handle::after {
    content: ""; position: absolute; left: 50%; top: 1px; width: 36px; height: 4px;
    margin-left: -18px; border-radius: 2px; background: #fd4f00; opacity: 0;
    transition: opacity 120ms ease;
  }
  .handle:hover::after, .handle:focus-visible::after, .handle.dragging::after { opacity: 1; }
  .handle.visible { display: block; }
  .pill {
    position: fixed; right: 12px; bottom: 12px; z-index: 2147483000;
    display: none; align-items: center; gap: 6px;
    height: 28px; padding: 0 12px; border: 0; border-radius: 14px;
    background: #1f2330; color: #fd4f00; cursor: pointer;
    font: 600 12px/28px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    box-shadow: 0 2px 10px rgba(0, 0, 0, .3);
    transition: transform 120ms ease;
  }
  .pill:hover { transform: translateY(-1px); }
  .pill:focus-visible { outline: 2px solid #fd4f00; outline-offset: 2px; }
  .pill.visible { display: inline-flex; }
  @media (prefers-reduced-motion: reduce) { .frame, .pill, .handle::after { transition: none; } }
`

const mount = () => {
  const {pdtSid: sid, pdtPath: path} = script.dataset
  if (!sid || !path) return

  const host = document.createElement("div")
  host.id = "phoenix-dev-toolbar"
  host.setAttribute("data-phx-update", "ignore")
  // Inline so host page rules cannot reach it. Its height is the space the bar
  // reserves in the page flow, so the page scrolls its end above the bar.
  host.style.cssText = "display:block;margin:0;padding:0;border:0;height:0"
  const root = host.attachShadow({mode: "open"})

  const style = document.createElement("style")
  style.textContent = STYLE

  const frame = document.createElement("iframe")
  frame.className = "frame"
  frame.title = "Phoenix dev toolbar"
  frame.src = `${path}/panel?sid=${encodeURIComponent(sid)}`

  const pill = document.createElement("button")
  pill.className = "pill"
  pill.type = "button"
  pill.textContent = "dev toolbar"
  pill.title = "Show the dev toolbar"

  const handle = document.createElement("div")
  handle.className = "handle"
  handle.tabIndex = 0
  handle.title = "Drag to resize, double click to reset"
  handle.setAttribute("role", "separator")
  handle.setAttribute("aria-orientation", "horizontal")
  handle.setAttribute("aria-label", "Resize the dev toolbar")

  root.append(style, frame, handle, pill)
  document.body.appendChild(host)

  let state = readState()
  const layout = readLayout()
  const viewport = () => window.innerHeight
  // `wanted` is the user's size; `size` is it clamped to the current viewport,
  // so shrinking the window and growing it back restores the user's size.
  let wanted = layout.size
  let size = clampSize(wanted, viewport())
  const post = (type, payload = {}) =>
    frame.contentWindow &&
    frame.contentWindow.postMessage({type: MESSAGE_PREFIX + type, ...payload}, window.location.origin)

  const applySize = () => {
    host.style.setProperty("--pdt-size", `${size}px`)
    host.style.height = `${reservedSize(state, size)}px`
    handle.setAttribute("aria-valuemin", String(MIN_SIZE))
    handle.setAttribute("aria-valuemax", String(Math.max(MIN_SIZE, viewport() - PAGE_STRIP)))
    handle.setAttribute("aria-valuenow", String(size))
  }

  const resize = (next, persist) => {
    size = clampSize(next, viewport())
    applySize()
    if (!persist) return
    wanted = size
    writeLayout({dock: layout.dock, size})
  }

  const setState = (next) => {
    state = next
    frame.classList.toggle("open", state === "open")
    frame.classList.toggle("hidden", state === "hidden")
    handle.classList.toggle("visible", state === "open")
    pill.classList.toggle("visible", state === "hidden")
    applySize()
    writeState(state)
    post("state", {open: state === "open"})
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
    drag = {frame: null, y: event.clientY}
    frame.classList.add("dragging")
    handle.classList.add("dragging")
  })
  handle.addEventListener("pointermove", (event) => {
    if (!drag) return
    drag.y = event.clientY
    if (drag.frame) return
    drag.frame = requestAnimationFrame(() => {
      if (!drag) return
      drag.frame = null
      resize(viewport() - drag.y, false)
    })
  })
  handle.addEventListener("pointerup", endDrag)
  handle.addEventListener("pointercancel", endDrag)
  handle.addEventListener("lostpointercapture", endDrag)
  handle.addEventListener("dblclick", () => resize(defaultSize(viewport()), true))
  handle.addEventListener("keydown", (event) => {
    const step = event.shiftKey ? KEY_STEP_LARGE : KEY_STEP
    const next = {
      ArrowUp: size + step,
      ArrowDown: size - step,
      Home: defaultSize(viewport()),
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
        resize(wanted, false)
      })
    },
    {passive: true},
  )

  pill.addEventListener("click", () => setState("collapsed"))
  frame.addEventListener("load", () => {
    post("state", {open: state === "open"})
    queue.ready()
  })

  // Only our own iframe, on our own origin, may drive the container.
  window.addEventListener("message", (event) => {
    if (event.origin !== window.location.origin || event.source !== frame.contentWindow) return
    const type = event.data && event.data.type

    if (type === "pdt:toggle") setState(state === "open" ? "collapsed" : "open")
    if (type === "pdt:open") setState("open")
    if (type === "pdt:close") setState("collapsed")
    if (type === "pdt:hide") setState("hidden")
  })

  setState(state)
}

// Never inside iframes (including our own panel) and never twice per page.
if (script && window.top === window && !window.__phoenixDevToolbar) {
  window.__phoenixDevToolbar = true

  if (document.body) {
    mount()
  } else {
    document.addEventListener("DOMContentLoaded", mount, {once: true})
  }
}
