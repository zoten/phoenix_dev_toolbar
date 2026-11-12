// DOM-level tests for the loader's wiring (ADR 04, ADR 07): mount, the
// postMessage bridge and its origin gate, state, docks, client events. The
// real assets/js/loader.js runs against a fake DOM (support/fake_dom.mjs).
// Run with `mix test.js` (node --test, Node built-ins only).
import {test} from "node:test"
import assert from "node:assert/strict"

import {PER_SECOND} from "../client_events.mjs"
import {BlockedStorage, FakeEvent, FakeWindow, freshImport, installDom, message} from "./support/fake_dom.mjs"

const ORIGIN = "http://localhost:4000"
const LOADER = new URL("../loader.js", import.meta.url)

// Runs the loader on a page. Timers are mocked (the drop report waits a second).
// `setup` prepares the page before the loader runs.
const load = async (t, {attributes = {}, nonce, page = {}, setup = () => {}} = {}) => {
  t.mock.timers.enable({apis: ["setTimeout"]})
  const env = installDom({origin: ORIGIN, ...page})
  t.after(env.restore)
  setup(env)
  env.script({"data-pdt-sid": "s1", "data-pdt-path": "/__pdt", ...attributes}, nonce)
  await freshImport(LOADER)

  const host = env.document.getElementById("phoenix-dev-toolbar")
  const root = host && host.shadowRoot
  const frame = root && root.querySelector("iframe")
  const fromPanel = (data, opts = {}) =>
    env.window.dispatchEvent(message(data, {origin: ORIGIN, source: frame.contentWindow, ...opts}))
  const posted = () => frame.contentWindow.posted
  const lastState = () => posted().filter(({data}) => data.type === "pdt:state").at(-1).data

  return {...env, host, root, frame, pill: root && root.querySelector("button"), fromPanel, posted, lastState}
}

test("mounts one shadow host with the panel iframe at the end of <body>", async (t) => {
  const page = await load(t, {attributes: {"data-pdt-sid": "a b&c"}})

  assert.equal(page.document.body.lastChild, page.host)
  assert.equal(page.host.getAttribute("data-phx-update"), "ignore")
  assert.equal(page.frame.src, "/__pdt/panel?sid=a%20b%26c")
  assert.equal(page.document.querySelectorAll("#phoenix-dev-toolbar").length, 1)
})

test("does not mount inside an iframe", async (t) => {
  const page = await load(t, {page: {framed: true}})

  assert.equal(page.host, null)
})

test("does not mount without a sid", async (t) => {
  const page = await load(t, {attributes: {"data-pdt-sid": ""}})

  assert.equal(page.host, null)
})

test("a script evaluated twice mounts once", async (t) => {
  const page = await load(t)
  page.script({"data-pdt-sid": "s2", "data-pdt-path": "/__pdt"})
  await freshImport(LOADER)
  assert.equal(page.document.querySelectorAll("#phoenix-dev-toolbar").length, 1)
})

test("waits for DOMContentLoaded when the script runs before <body>", async (t) => {
  const page = await load(t, {page: {body: false}})
  assert.equal(page.host, null)

  page.document.documentElement.append(page.document.createElement("body"))
  page.document.dispatchEvent(new FakeEvent("DOMContentLoaded"))

  assert.notEqual(page.document.getElementById("phoenix-dev-toolbar"), null)
})

test("carries the page's CSP nonce to its shadow style", async (t) => {
  const page = await load(t, {nonce: "n0nce"})

  assert.equal(page.root.querySelector("style").getAttribute("nonce"), "n0nce")
})

test("origin gate: only its own iframe, on the page's origin, drives the toolbar", async (t) => {
  const page = await load(t)
  const collapsed = () => page.window.localStorage.getItem("pdt:state") === "collapsed"
  assert.ok(collapsed())

  page.fromPanel({type: "pdt:open"}, {origin: "http://evil.test"})
  assert.ok(collapsed(), "another origin is ignored")

  page.fromPanel({type: "pdt:open"}, {source: new FakeWindow({origin: ORIGIN})})
  assert.ok(collapsed(), "another window on the same origin is ignored")

  page.fromPanel({type: "pdt:open"}, {origin: "null"})
  assert.ok(collapsed(), "an opaque origin is ignored")

  page.fromPanel({type: "pdt:open"})
  assert.equal(page.window.localStorage.getItem("pdt:state"), "open")
})

test("posts to the panel on the page's own origin only, never '*'", async (t) => {
  const page = await load(t)
  page.frame.dispatchEvent(new FakeEvent("load"))
  page.fromPanel({type: "pdt:toggle"})

  assert.equal(page.posted().length, 3, "the mount state, the load, the toggle")
  page.posted().forEach(({targetOrigin}) => assert.equal(targetOrigin, ORIGIN))
  assert.deepEqual(page.lastState(), {type: "pdt:state", open: true, dock: "bottom", reserve: true, shortcut: null, theme: "auto"})
})

test("toggle, hide and the corner pill move between the three states", async (t) => {
  const page = await load(t)
  const state = () => page.window.localStorage.getItem("pdt:state")

  page.fromPanel({type: "pdt:toggle"})
  assert.equal(state(), "open")
  assert.equal(page.host.style.height, "360px")
  assert.equal(page.host.style.getPropertyValue("--pdt-extent"), "360px")

  page.fromPanel({type: "pdt:close"})
  assert.equal(state(), "collapsed")
  assert.equal(page.host.style.height, "34px")

  page.fromPanel({type: "pdt:hide"})
  assert.equal(state(), "hidden")
  assert.ok(page.frame.classList.contains("hidden"))
  assert.ok(page.pill.classList.contains("visible"))
  assert.equal(page.host.style.height, "0px")

  page.pill.click()
  assert.equal(state(), "collapsed")
  assert.ok(!page.pill.classList.contains("visible"))
})

test("blocked storage still mounts, collapsed", async (t) => {
  const page = await load(t, {setup: ({window}) => (window.localStorage = new BlockedStorage())})

  assert.equal(page.host.style.height, "34px")
  assert.ok(page.pill && !page.pill.classList.contains("visible"))
})

test("restores the stored state and migrates the legacy open flag", async (t) => {
  const page = await load(t, {setup: ({window}) => window.localStorage.setItem("pdt:open", "1")})

  assert.equal(page.window.localStorage.getItem("pdt:state"), "open")
  assert.equal(page.window.localStorage.getItem("pdt:open"), null)
})

test("a dock message moves the toolbar, pads <html> on a side and is stored", async (t) => {
  const page = await load(t, {setup: ({document}) => document.documentElement.style.setProperty("padding-right", "3px")})
  const html = page.document.documentElement

  page.fromPanel({type: "pdt:dock", dock: "top"})
  assert.equal(page.document.body.firstChild, page.host)
  assert.ok(page.frame.classList.contains("dock-top"))

  page.fromPanel({type: "pdt:dock", dock: "right"})
  assert.equal(page.host.style.height, "0")
  assert.equal(html.style.getPropertyValue("padding-right"), "calc(0px + 34px)")
  assert.equal(html.style.getPropertyPriority("padding-right"), "important")
  assert.equal(JSON.parse(page.window.localStorage.getItem("pdt:layout")).dock, "right")

  page.fromPanel({type: "pdt:dock", dock: "bottom"})
  assert.equal(html.style.getPropertyValue("padding-right"), "3px", "the host's own padding is back")

  page.fromPanel({type: "pdt:dock", dock: "<script>"})
  assert.ok(page.frame.classList.contains("dock-bottom"), "an unknown dock is ignored")
})

test("a reserve message takes booleans only and stops reserving page space", async (t) => {
  const page = await load(t)

  page.fromPanel({type: "pdt:reserve", reserve: "false"})
  assert.equal(page.host.style.height, "34px")

  page.fromPanel({type: "pdt:reserve", reserve: false})
  assert.equal(page.host.style.height, "0px")
  assert.equal(JSON.parse(page.window.localStorage.getItem("pdt:layout")).reserve, false)
})

test("a theme message is saved and echoed in the state; unknown values are ignored", async (t) => {
  const page = await load(t)
  const stored = () => page.window.localStorage.getItem("pdt:layout")

  page.fromPanel({type: "pdt:theme", theme: "dark"})
  assert.equal(page.lastState().theme, "dark")
  assert.equal(JSON.parse(stored()).theme, "dark")

  page.fromPanel({type: "pdt:theme", theme: "neon"})
  page.fromPanel({type: "pdt:theme", theme: 7})
  assert.equal(page.lastState().theme, "dark")

  page.fromPanel({type: "pdt:theme", theme: "auto"})
  assert.equal(page.lastState().theme, "auto")
  assert.equal(JSON.parse(stored()).theme, undefined)
})

test("a theme message from a foreign origin or source is ignored", async (t) => {
  const page = await load(t)

  page.fromPanel({type: "pdt:theme", theme: "light"}, {origin: "http://evil.test"})
  page.fromPanel({type: "pdt:theme", theme: "light"}, {source: page.window})
  assert.equal(page.lastState().theme, "auto")
  assert.equal(page.window.localStorage.getItem("pdt:layout"), null)
})

test("the stored theme is sent with the first state", async (t) => {
  const page = await load(t, {
    setup: (env) => env.window.localStorage.setItem("pdt:layout", '{"dock":"bottom","sizes":{},"theme":"light"}'),
  })
  assert.equal(page.lastState().theme, "light")
})

test("the server's data-pdt-reserve=false default yields to the stored choice", async (t) => {
  const page = await load(t, {attributes: {"data-pdt-reserve": "false"}})
  assert.equal(page.host.style.height, "0px")

  page.fromPanel({type: "pdt:reserve", reserve: true})
  assert.equal(page.host.style.height, "34px")
})

test("client events wait for the iframe, then go out sanitized", async (t) => {
  const page = await load(t)
  const clientEvents = () => page.posted().filter(({data}) => data.type === "pdt:client")

  page.window.dispatchEvent(new FakeEvent("phx:navigate", {detail: {href: "/posts", secret: "x"}}))
  page.window.dispatchEvent(new FakeEvent("phx:unknown", {detail: {}}))
  assert.equal(clientEvents().length, 0)

  page.frame.dispatchEvent(new FakeEvent("load"))
  const [{data}] = clientEvents()
  assert.equal(clientEvents().length, 1)
  assert.equal(data.event.type, "phx:navigate")
  assert.equal(data.event.href, "/posts")
  assert.equal(data.event.secret, undefined)
  assert.equal(data.dropped, 0)
})

test("a client event listener never throws into the host's dispatch", async (t) => {
  const page = await load(t)
  page.frame.dispatchEvent(new FakeEvent("load"))
  const detail = {
    get kind() {
      throw new Error("hostile getter")
    },
  }
  const clientEvents = () => page.posted().filter(({data}) => data.type === "pdt:client")
  const before = clientEvents().length

  assert.doesNotThrow(() => page.window.dispatchEvent(new FakeEvent("phx:navigate", {detail})))
  assert.equal(clientEvents().length, before + 1, "the event still goes out, without the hostile field")
  assert.equal(clientEvents().at(-1).data.event.type, "phx:navigate")
  assert.equal(clientEvents().at(-1).data.event.kind, undefined)
})

test("a burst past the rate limit reports its drops a second later", async (t) => {
  const page = await load(t)
  page.frame.dispatchEvent(new FakeEvent("load"))
  for (let i = 0; i < 100; i++) page.window.dispatchEvent(new FakeEvent("phx:navigate", {detail: {}}))

  t.mock.timers.tick(1000)
  const report = page.posted().filter(({data}) => data.type === "pdt:client").at(-1).data

  assert.equal(report.event, null)
  assert.equal(report.dropped, 100 - PER_SECOND)
})

test("the keyboard resizes the open panel and stores its size", async (t) => {
  const page = await load(t)
  page.fromPanel({type: "pdt:open"})
  const handle = page.root.querySelector(".handle")
  const before = Number(handle.getAttribute("aria-valuenow"))

  handle.dispatchEvent(new FakeEvent("keydown", {key: "ArrowUp", shiftKey: false}))

  assert.equal(Number(handle.getAttribute("aria-valuenow")), before + 16)
  assert.equal(JSON.parse(page.window.localStorage.getItem("pdt:layout")).sizes.bottom, before + 16)
})

test("hiding moves focus to the pill only when the frame had it", async (t) => {
  const page = await load(t)
  page.frame.focus()
  page.fromPanel({type: "pdt:hide"})
  assert.equal(page.root.activeElement, page.pill)
})

test("neither loading nor hiding takes focus when the frame had none", async (t) => {
  const page = await load(t)
  assert.equal(page.root.activeElement, null)
  page.fromPanel({type: "pdt:hide"})
  assert.equal(page.root.activeElement, null)
})

test("hiding leaves focus alone when it was elsewhere on the page", async (t) => {
  const page = await load(t)
  const input = page.document.createElement("input")
  page.document.body.append(input)
  input.focus()
  page.fromPanel({type: "pdt:hide"})

  assert.equal(page.document.activeElement, input)
})

test("hiding after focus moved from the frame to the page keeps it there", async (t) => {
  const page = await load(t)
  const input = page.document.createElement("input")
  page.document.body.append(input)
  page.frame.focus()
  input.focus()
  page.fromPanel({type: "pdt:hide"})

  assert.equal(page.document.activeElement, input)
  assert.notEqual(page.root.activeElement, page.pill)
})

test("the pill focuses the frame and asks the panel to focus its toggle", async (t) => {
  const page = await load(t)
  page.fromPanel({type: "pdt:hide"})
  page.pill.click()

  assert.equal(page.root.activeElement, page.frame)
  const last = page.posted().at(-1)
  assert.deepEqual(last.data, {type: "pdt:focus"})
  assert.equal(last.targetOrigin, ORIGIN)
})

test("the handle's aria-valuetext follows keyboard resizes", async (t) => {
  const page = await load(t)
  const handle = openHandle(page)
  assert.equal(handle.getAttribute("aria-valuetext"), "360 pixels")

  handle.dispatchEvent(new FakeEvent("keydown", {key: "ArrowUp", shiftKey: false}))
  assert.equal(handle.getAttribute("aria-valuetext"), "376 pixels")
})

// Pointer events on the resize handle, as the browser fires them.
const pointer = (type, {x = 0, y = 0, button = 0} = {}) =>
  new FakeEvent(type, {button, pointerId: 1, clientX: x, clientY: y})

const openHandle = (page) => {
  page.fromPanel({type: "pdt:open"})
  return page.root.querySelector(".handle")
}

const storedSize = (page, dock = "bottom") => JSON.parse(page.window.localStorage.getItem("pdt:layout")).sizes[dock]

test("dragging the handle resizes once per frame to the pointer, and the end stores the size", async (t) => {
  const page = await load(t)
  const handle = openHandle(page)
  assert.equal(handle.getAttribute("aria-valuenow"), "360")

  handle.dispatchEvent(pointer("pointerdown", {y: 440}))
  assert.ok(page.frame.classList.contains("dragging"), "the iframe stops swallowing the pointer")
  assert.ok(handle.classList.contains("dragging"))

  handle.dispatchEvent(pointer("pointermove", {y: 500}))
  handle.dispatchEvent(pointer("pointermove", {y: 600}))
  assert.equal(handle.getAttribute("aria-valuenow"), "360", "nothing moves before the frame")

  page.flushFrames()
  assert.equal(handle.getAttribute("aria-valuenow"), "200", "the last position wins: 800 - 600")
  assert.equal(page.host.style.getPropertyValue("--pdt-extent"), "200px")
  assert.equal(page.window.localStorage.getItem("pdt:layout"), null, "a drag in flight is not stored")

  handle.dispatchEvent(pointer("pointerup", {y: 600}))
  assert.ok(!page.frame.classList.contains("dragging"))
  assert.ok(!handle.classList.contains("dragging"))
  assert.equal(storedSize(page), 200)
})

test("a drag is clamped to the panel's bounds", async (t) => {
  const page = await load(t)
  const handle = openHandle(page)

  handle.dispatchEvent(pointer("pointerdown"))
  handle.dispatchEvent(pointer("pointermove", {y: 790}))
  page.flushFrames()
  assert.equal(handle.getAttribute("aria-valuenow"), "120", "never below the minimum")

  handle.dispatchEvent(pointer("pointermove", {y: 0}))
  page.flushFrames()
  assert.equal(handle.getAttribute("aria-valuenow"), "752", "always a strip of page left")
})

test("only the primary button drags, and moves without a drag do nothing", async (t) => {
  const page = await load(t)
  const handle = openHandle(page)

  handle.dispatchEvent(pointer("pointerdown", {button: 2, y: 400}))
  assert.ok(!page.frame.classList.contains("dragging"))

  handle.dispatchEvent(pointer("pointermove", {y: 100}))
  page.flushFrames()
  assert.equal(handle.getAttribute("aria-valuenow"), "360")
})

test("losing the pointer capture ends the drag like a release", async (t) => {
  const page = await load(t)
  const handle = openHandle(page)

  handle.dispatchEvent(pointer("pointerdown"))
  handle.dispatchEvent(pointer("pointermove", {y: 500}))
  handle.dispatchEvent(pointer("lostpointercapture"))
  page.flushFrames()

  assert.ok(!page.frame.classList.contains("dragging"))
  assert.equal(handle.getAttribute("aria-valuenow"), "360", "the frame that was pending is cancelled")
  assert.equal(storedSize(page), 360)
})

test("a side dock measures the drag from its own edge", async (t) => {
  const page = await load(t)
  const handle = openHandle(page)
  page.fromPanel({type: "pdt:dock", dock: "right"})

  handle.dispatchEvent(pointer("pointerdown"))
  handle.dispatchEvent(pointer("pointermove", {x: 900}))
  page.flushFrames()
  handle.dispatchEvent(pointer("pointerup", {x: 900}))

  assert.equal(handle.getAttribute("aria-valuenow"), "380", "1280 - 900")
  assert.equal(storedSize(page, "right"), 380)
})

test("double click resets the panel to its default size", async (t) => {
  const page = await load(t)
  const handle = openHandle(page)
  handle.dispatchEvent(new FakeEvent("keydown", {key: "ArrowUp", shiftKey: true}))
  assert.equal(handle.getAttribute("aria-valuenow"), "424")

  handle.dispatchEvent(new FakeEvent("dblclick"))

  assert.equal(handle.getAttribute("aria-valuenow"), "360")
  assert.equal(storedSize(page), 360)
})

test("a window resize re-clamps the panel once per frame, and growing back restores the user's size", async (t) => {
  const page = await load(t)
  const handle = openHandle(page)
  handle.dispatchEvent(pointer("pointerdown"))
  handle.dispatchEvent(pointer("pointermove", {y: 100}))
  page.flushFrames()
  handle.dispatchEvent(pointer("pointerup", {y: 100}))
  assert.equal(handle.getAttribute("aria-valuenow"), "700")

  page.window.innerHeight = 400
  page.window.dispatchEvent(new FakeEvent("resize"))
  page.window.dispatchEvent(new FakeEvent("resize"))
  assert.equal(page.pendingFrames(), 1, "a burst of resizes asks for one frame")
  assert.equal(handle.getAttribute("aria-valuenow"), "700", "nothing before the frame")
  page.flushFrames()
  assert.equal(handle.getAttribute("aria-valuenow"), "352")
  assert.equal(handle.getAttribute("aria-valuemax"), "352")
  assert.equal(storedSize(page), 700, "shrinking the window does not overwrite the stored size")

  page.window.innerHeight = 800
  page.window.dispatchEvent(new FakeEvent("resize"))
  page.flushFrames()
  assert.equal(handle.getAttribute("aria-valuenow"), "700")
})

for (const [value, expected] of [
  [undefined, null],
  ["bottom-right", null],
  ["middle", null],
  ["bottom-left", "corner-bottom-left"],
  ["top-right", "corner-top-right"],
  ["top-left", "corner-top-left"],
]) {
  test(`pill corner ${value}: ${expected || "the default bottom right"}`, async (t) => {
    const page = await load(t, {attributes: value ? {"data-pdt-pill": value} : {}})
    const classes = page.pill.className.split(" ")

    assert.equal(classes.filter((name) => name.startsWith("corner-")).join(), expected || "")
  })
}

test("shortcut: without the attribute, no keydown listener and null in the state", async (t) => {
  const page = await load(t)

  assert.equal(page.window.listeners.get("keydown"), undefined)
  assert.equal(page.lastState().shortcut, null)
  assert.equal(page.pill.title, "Show the dev toolbar")
})

test("shortcut: an invalid attribute attaches nothing", async (t) => {
  const page = await load(t, {attributes: {"data-pdt-shortcut": "d"}})

  assert.equal(page.window.listeners.get("keydown"), undefined)
  assert.equal(page.lastState().shortcut, null)
})

test("shortcut: toggles open and collapsed, brings a hidden toolbar back collapsed", async (t) => {
  const page = await load(t, {attributes: {"data-pdt-shortcut": "ctrl+shift+d"}})
  const state = () => page.window.localStorage.getItem("pdt:state")
  const press = (init = {}) => {
    const event = new FakeEvent("keydown", {code: "KeyD", ctrlKey: true, shiftKey: true, target: page.document.body, ...init})
    page.window.dispatchEvent(event)
    return event
  }

  assert.ok(press().defaultPrevented)
  assert.equal(state(), "open")
  press()
  assert.equal(state(), "collapsed")

  page.fromPanel({type: "pdt:hide"})
  press()
  assert.equal(state(), "collapsed")
  assert.ok(!page.pill.classList.contains("visible"))
  assert.equal(page.lastState().shortcut, "ctrl+shift+d")
  assert.equal(page.pill.title, "Show the dev toolbar (Ctrl+Shift+D)")
})

test("shortcut: other keys, repeats, composition and typing are left alone", async (t) => {
  const page = await load(t, {attributes: {"data-pdt-shortcut": "alt+f5"}})
  const state = () => page.window.localStorage.getItem("pdt:state")
  const press = (init) => {
    const event = new FakeEvent("keydown", {code: "F5", altKey: true, target: page.document.body, ...init})
    page.window.dispatchEvent(event)
    return event
  }

  for (const init of [
    {code: "F6"},
    {ctrlKey: true},
    {repeat: true},
    {isComposing: true},
    {target: {tagName: "TEXTAREA"}},
    {target: {tagName: "DIV", isContentEditable: true}},
  ]) {
    assert.ok(!press(init).defaultPrevented, JSON.stringify(init))
    assert.equal(state(), "collapsed")
  }
  press({})
  assert.equal(state(), "open")
})

test("shortcut: a throwing listener never reaches the host", async (t) => {
  const page = await load(t, {attributes: {"data-pdt-shortcut": "alt+f5"}})
  const event = new FakeEvent("keydown", {code: "F5", altKey: true})
  Object.defineProperty(event, "code", {get() { throw new Error("boom") }})

  page.window.dispatchEvent(event)
})

// Element inspector (ADR 16)

// A LiveView with a component annotation around a button, plus a host handler
// on the button that must not run while the picker is armed.
const withView = (env) => {
  const view = env.build([
    "div",
    {id: "phx-F1", "data-phx-session": "s"},
    ["#comment", " <Demo.Core.button> lib/x.ex:12 (demo) "],
    ["button", {id: "target", "phx-click": "save", "data-phx-loc": "7"}],
    ["div", {"data-phx-component": "3", id: "comp"}],
  ])
  env.document.body.append(view)
  const target = env.document.getElementById("target")
  target.rect = {left: 10, top: 40, width: 100, height: 30}
  const hostClicks = []
  target.addEventListener("click", (event) => hostClicks.push(event))
  return {view, target, hostClicks}
}

const inspectorPage = async (t) => {
  let view
  const page = await load(t, {setup: (env) => (view = withView(env))})
  const picking = () => page.posted().filter(({data}) => data.type === "pdt:picking").map(({data}) => data.armed)
  const inspected = () => page.posted().filter(({data}) => data.type === "pdt:inspect")
  const boxes = () => page.root.querySelectorAll(".pick-box")
  const hover = (target) => {
    page.document.dispatchEvent(new FakeEvent("pointermove", {target}))
    page.flushFrames()
  }
  const click = (target) => {
    const event = new FakeEvent("click", {button: 0})
    target.dispatchEvent(event)
    return event
  }
  return {...page, ...view, picking, inspected, boxes, hover, click}
}

test("pdt:pick arms the picker and reports it", async (t) => {
  const page = await inspectorPage(t)

  page.fromPanel({type: "pdt:pick"})

  assert.deepEqual(page.picking(), [true])
})

test("a second pdt:pick disarms and removes the listeners", async (t) => {
  const page = await inspectorPage(t)

  page.fromPanel({type: "pdt:pick"})
  page.fromPanel({type: "pdt:pick"})

  assert.deepEqual(page.picking(), [true, false])
  for (const type of ["pointermove", "click", "keydown"]) {
    assert.equal((page.document.listeners.get(type) || []).length, 0, type)
  }
})

test("nothing is intercepted until armed", async (t) => {
  const page = await inspectorPage(t)

  const event = page.click(page.target)

  assert.ok(!event.defaultPrevented)
  assert.equal(page.hostClicks.length, 1)
  assert.equal((page.document.listeners.get("click") || []).length, 0)
})

test("hovering outlines the element, once per animation frame", async (t) => {
  const page = await inspectorPage(t)
  page.fromPanel({type: "pdt:pick"})

  page.document.dispatchEvent(new FakeEvent("pointermove", {target: page.target}))
  page.document.dispatchEvent(new FakeEvent("pointermove", {target: page.target}))

  assert.equal(page.pendingFrames(), 1)
  page.flushFrames()
  const [box] = page.boxes()
  assert.equal(box.style.getPropertyValue("left"), "10px")
  assert.equal(box.style.getPropertyValue("width"), "100px")
  assert.equal(page.root.querySelector(".pick-label").textContent, "button in Demo.Core.button")
})

test("hovering the toolbar itself draws no outline", async (t) => {
  const page = await inspectorPage(t)
  page.fromPanel({type: "pdt:pick"})
  page.hover(page.target)

  page.hover(page.host)

  assert.equal(page.boxes().length, 0)
})

test("armed click posts the payload, disarms, opens the panel and swallows the click", async (t) => {
  const page = await inspectorPage(t)
  page.fromPanel({type: "pdt:pick"})

  const event = page.click(page.target)

  assert.ok(event.defaultPrevented)
  assert.equal(page.hostClicks.length, 0)
  assert.deepEqual(page.inspected().map(({data}) => data.inspected), [
    {
      root: "phx-F1",
      cid: null,
      tag: "button",
      tag_line: 7,
      binding: {event: "phx-click", name: "save", target: null},
      frames: [{name: "Demo.Core.button", file: "lib/x.ex", line: 12}],
      caller: null,
    },
  ])
  assert.deepEqual(page.picking(), [true, false])
  assert.equal(page.lastState().open, true)
  assert.equal(page.boxes().length, 0)
  assert.equal(page.click(page.target).defaultPrevented, false)
})

test("a click on the toolbar while armed is ignored", async (t) => {
  const page = await inspectorPage(t)
  page.fromPanel({type: "pdt:pick"})

  const event = page.click(page.host)

  assert.ok(!event.defaultPrevented)
  assert.deepEqual(page.picking(), [true])
  assert.equal(page.inspected().length, 0)
})

test("Escape disarms without posting an inspection", async (t) => {
  const page = await inspectorPage(t)
  page.fromPanel({type: "pdt:pick"})
  page.hover(page.target)

  page.document.body.dispatchEvent(new FakeEvent("keydown", {key: "Escape"}))

  assert.deepEqual(page.picking(), [true, false])
  assert.equal(page.inspected().length, 0)
  assert.equal(page.boxes().length, 0)
})

test("pick messages from another origin are ignored", async (t) => {
  const page = await inspectorPage(t)

  page.fromPanel({type: "pdt:pick"}, {origin: "http://evil.test"})

  assert.deepEqual(page.picking(), [])
})

test("pdt:highlight outlines a LiveView root and a component, in the shadow root", async (t) => {
  const page = await inspectorPage(t)
  page.document.getElementById("comp").rect = {left: 1, top: 2, width: 3, height: 4}

  page.fromPanel({type: "pdt:highlight", root: "phx-F1", cid: 3})

  assert.equal(page.boxes().length, 1)
  assert.equal(page.boxes()[0].style.getPropertyValue("height"), "4px")
  assert.equal(page.document.querySelectorAll(".pick-box").length, 0)
  assert.equal((page.document.listeners.get("click") || []).length, 0)
})

test("pdt:highlight with a null root clears the outline", async (t) => {
  const page = await inspectorPage(t)
  page.fromPanel({type: "pdt:highlight", root: "phx-F1", cid: null})

  page.fromPanel({type: "pdt:highlight", root: null, cid: null})

  assert.equal(page.boxes().length, 0)
})

test("the highlight clears after 3 seconds and on scroll", async (t) => {
  const page = await inspectorPage(t)
  page.fromPanel({type: "pdt:highlight", root: "phx-F1", cid: null})
  t.mock.timers.tick(3000)
  assert.equal(page.boxes().length, 0)

  page.fromPanel({type: "pdt:highlight", root: "phx-F1", cid: null})
  page.window.dispatchEvent(new FakeEvent("scroll"))
  assert.equal(page.boxes().length, 0)
})

test("pdt:highlight for an unknown root or component draws nothing", async (t) => {
  const page = await inspectorPage(t)

  page.fromPanel({type: "pdt:highlight", root: "nope", cid: null})
  page.fromPanel({type: "pdt:highlight", root: "phx-F1", cid: 99})
  page.fromPanel({type: "pdt:highlight", root: 5, cid: null})

  assert.equal(page.boxes().length, 0)
})
