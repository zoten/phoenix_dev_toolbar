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

const STORAGE_KEY = "pdt:state"
const LEGACY_KEY = "pdt:open"
const STATES = ["open", "collapsed", "hidden"]
const COLLAPSED_PX = 34
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

const STYLE = `
  :host { all: initial; }
  .frame {
    position: fixed; left: 0; right: 0; bottom: 0; z-index: 2147483000;
    width: 100%; height: ${COLLAPSED_PX}px; border: 0; margin: 0; padding: 0;
    box-shadow: 0 -1px 0 rgba(0, 0, 0, .25), 0 -4px 16px rgba(0, 0, 0, .12);
    background: transparent; color-scheme: normal;
    transition: height 120ms ease-out;
  }
  .frame.open { height: min(45vh, 520px); }
  .frame.hidden { display: none; }
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
  @media (prefers-reduced-motion: reduce) { .frame, .pill { transition: none; } }
`

const mount = () => {
  const {pdtSid: sid, pdtPath: path} = script.dataset
  if (!sid || !path) return

  const host = document.createElement("div")
  host.id = "phoenix-dev-toolbar"
  host.setAttribute("data-phx-update", "ignore")
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

  root.append(style, frame, pill)
  document.body.appendChild(host)

  let state = readState()
  const post = (type, payload = {}) =>
    frame.contentWindow &&
    frame.contentWindow.postMessage({type: MESSAGE_PREFIX + type, ...payload}, window.location.origin)

  const setState = (next) => {
    state = next
    frame.classList.toggle("open", state === "open")
    frame.classList.toggle("hidden", state === "hidden")
    pill.classList.toggle("visible", state === "hidden")
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
        const now = Date.now()
        if (limiter.allow(now)) queue.push(sanitize(name, event.detail, now))
        else reportDrops()
      },
      {passive: true},
    ),
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
