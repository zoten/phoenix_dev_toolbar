// phoenix_dev_toolbar loader (ADR 04).
//
// Injected by PhoenixDevToolbar.Plug before </body>. It only adds one element
// to the host page: a shadow-DOM host holding the panel iframe, so host CSS
// cannot reach the toolbar and the toolbar's CSS cannot reach the host. It is
// read-only towards the host page and never touches window.liveSocket's state.

const STORAGE_KEY = "pdt:open"
const COLLAPSED_PX = 34
const MESSAGE_PREFIX = "pdt:"

const script =
  document.currentScript || document.querySelector("script[data-pdt-sid]")

const readOpen = () => {
  try {
    return window.localStorage.getItem(STORAGE_KEY) === "1"
  } catch (_error) {
    return false
  }
}

const writeOpen = (open) => {
  try {
    window.localStorage.setItem(STORAGE_KEY, open ? "1" : "0")
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
  @media (prefers-reduced-motion: reduce) { .frame { transition: none; } }
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

  root.append(style, frame)
  document.body.appendChild(host)

  let open = readOpen()
  const post = (type, payload = {}) =>
    frame.contentWindow &&
    frame.contentWindow.postMessage({type: MESSAGE_PREFIX + type, ...payload}, window.location.origin)

  const setOpen = (value) => {
    open = value
    frame.classList.toggle("open", open)
    writeOpen(open)
    post("state", {open})
  }

  frame.addEventListener("load", () => post("state", {open}))

  // Only our own iframe, on our own origin, may drive the container.
  window.addEventListener("message", (event) => {
    if (event.origin !== window.location.origin || event.source !== frame.contentWindow) return
    const type = event.data && event.data.type

    if (type === "pdt:toggle") setOpen(!open)
    if (type === "pdt:open") setOpen(true)
    if (type === "pdt:close") setOpen(false)
  })

  setOpen(open)
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
