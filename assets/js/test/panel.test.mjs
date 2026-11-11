// DOM-level tests for the panel's wiring (ADR 04, ADR 07): the postMessage
// bridge to the loader and its origin gate, header clicks, the PdtPanel hook,
// the join timeout and the reload breaker. The real assets/js/panel.js runs
// against a fake DOM (support/fake_dom.mjs) and a fake LiveSocket.
// Run with `mix test.js` (node --test, Node built-ins only).
import {test} from "node:test"
import assert from "node:assert/strict"

import {FakeEvent, FakeWindow, freshImport, installDom, message} from "./support/fake_dom.mjs"

const ORIGIN = "http://localhost:4000"
const PANEL = new URL("../panel.js", import.meta.url)

// The header of lib/phoenix_dev_toolbar/panel_layout.ex, reduced to what panel.js reads.
const HEADER = [
  "header",
  {class: "pdt-header"},
  ["div", {id: "pdt-bridge", "phx-hook": "PdtPanel", hidden: true}],
  ["span", {class: "pdt-logo"}, "dev toolbar"],
  [
    "nav",
    {class: "pdt-tabs", role: "tablist"},
    ["button", {id: "pdt-tab-request", role: "tab"}, "Request"],
    ["button", {id: "pdt-tab-ecto", role: "tab"}, "Ecto"],
  ],
  [
    "div",
    {id: "pdt-dock-picker"},
    ["button", {id: "pdt-dock", "data-pdt-dock-menu": true, "aria-expanded": "false"}],
    [
      "div",
      {id: "pdt-dock-menu", hidden: true},
      ...["bottom", "top", "left", "right"].map((dock) => [
        "button",
        {id: `pdt-dock-${dock}`, "data-pdt-dock": dock, "aria-pressed": "false"},
      ]),
      ["button", {id: "pdt-reserve", "data-pdt-reserve": true, "aria-pressed": "true"}],
    ],
  ],
  ["button", {id: "pdt-hide", "data-pdt-hide": true}],
  ["button", {id: "pdt-toggle", "data-pdt-toggle": true}],
]

class FakeLiveSocket {
  constructor(path, socket, options) {
    Object.assign(this, {path, socket, options, connected: false})
    FakeLiveSocket.last = this
  }

  connect() {
    this.connected = true
  }
}

// A LiveView hook instance: records its pushes.
const hook = (spec) => {
  const instance = Object.create(spec)
  instance.pushed = []
  instance.pushEvent = (event, payload) => instance.pushed.push({event, payload})
  return instance
}

// Runs the panel inside an iframe of the page at ORIGIN. Timers are mocked:
// the join timeout is 8 seconds.
const load = async (t, {framed = true, setup = () => {}} = {}) => {
  t.mock.timers.enable({apis: ["setTimeout"]})
  const env = installDom({origin: ORIGIN, search: "?sid=s1", framed})
  t.after(env.restore)
  env.window.Phoenix = {Socket: class {}}
  env.window.LiveView = {LiveSocket: FakeLiveSocket}
  env.document.body.append(env.build(HEADER))
  setup(env)
  env.script({"data-socket-path": "/__pdt/live"})
  await freshImport(PANEL)

  const socket = FakeLiveSocket.last
  const byId = (id) => env.document.getElementById(id)
  const fromLoader = (data, opts = {}) =>
    env.window.dispatchEvent(message(data, {origin: ORIGIN, source: env.window.parent, ...opts}))
  const toLoader = () => env.window.parent.posted
  const join = () => {
    const bridge = hook(socket.options.hooks.PdtPanel)
    bridge.mounted()
    return bridge
  }
  const html = env.document.documentElement.classList

  return {...env, socket, byId, fromLoader, toLoader, join, html}
}

test("connects its own LiveSocket with the panel's hooks", async (t) => {
  const page = await load(t)

  assert.equal(page.socket.path, "/__pdt/live")
  assert.deepEqual(Object.keys(page.socket.options.hooks).sort(), ["PdtExport", "PdtMarkdown", "PdtPanel", "PdtSummaryMore"])
  assert.ok(page.socket.connected)
})

test("origin gate: only the parent page, on the panel's origin, sets the state", async (t) => {
  const page = await load(t)
  const state = {type: "pdt:state", open: true, dock: "left", reserve: false}

  page.fromLoader(state, {origin: "http://evil.test"})
  page.fromLoader(state, {source: new FakeWindow({origin: ORIGIN})})
  page.fromLoader(state, {origin: "null"})
  assert.ok(!page.html.contains("pdt-open"), "foreign messages are ignored")

  page.fromLoader(state)
  assert.ok(page.html.contains("pdt-open"))
  assert.ok(page.html.contains("pdt-dock-left"))
  assert.ok(page.html.contains("pdt-side"))
  assert.equal(page.byId("pdt-dock-left").getAttribute("aria-pressed"), "true")
  assert.equal(page.byId("pdt-dock-bottom").getAttribute("aria-pressed"), "false")
  assert.equal(page.byId("pdt-reserve").getAttribute("aria-pressed"), "false")
})

test("a state with an unknown dock or a non boolean reserve keeps the current ones", async (t) => {
  const page = await load(t)
  page.fromLoader({type: "pdt:state", open: false, dock: "top", reserve: true})

  page.fromLoader({type: "pdt:state", open: false, dock: "nowhere", reserve: "no"})

  assert.ok(page.html.contains("pdt-dock-top"))
  assert.equal(page.byId("pdt-reserve").getAttribute("aria-pressed"), "true")
})

test("header clicks post to the parent page on the panel's origin only", async (t) => {
  const page = await load(t)

  page.byId("pdt-toggle").click()
  page.byId("pdt-hide").click()
  page.byId("pdt-tab-ecto").click()
  page.byId("pdt-dock-right").click()
  page.byId("pdt-reserve").click()

  assert.deepEqual(
    page.toLoader().map(({data}) => data),
    [
      {type: "pdt:toggle"},
      {type: "pdt:hide"},
      {type: "pdt:open"},
      {type: "pdt:dock", dock: "right"},
      {type: "pdt:reserve", reserve: false},
    ],
  )
  page.toLoader().forEach(({targetOrigin}) => assert.equal(targetOrigin, ORIGIN))
})

test("opened as a top level page, it posts nothing", async (t) => {
  const page = await load(t, {framed: false})

  page.byId("pdt-toggle").click()

  assert.deepEqual(page.window.posted, [])
})

test("opened as a top level page, it is a standalone open panel", async (t) => {
  const page = await load(t, {framed: false})

  assert.ok(page.html.contains("pdt-standalone"))
  assert.ok(page.html.contains("pdt-open"))
  assert.ok(page.html.contains("pdt-dock-bottom"))
  assert.deepEqual(page.join().pushed, [{event: "pdt:visibility", payload: {open: true, visible: true}}])
})

test("in the loader's iframe, it waits for the loader's state", async (t) => {
  const page = await load(t)

  assert.ok(!page.html.contains("pdt-standalone"))
  assert.ok(!page.html.contains("pdt-open"))
})

test("the dock menu opens on its button and closes on Escape", async (t) => {
  const page = await load(t)
  const menu = page.byId("pdt-dock-menu")

  page.byId("pdt-dock").click()
  assert.equal(menu.hidden, false)
  assert.equal(page.byId("pdt-dock").getAttribute("aria-expanded"), "true")

  page.byId("pdt-dock-top").dispatchEvent(new FakeEvent("keydown", {key: "Escape"}))
  assert.equal(menu.hidden, true)
  assert.equal(page.document.activeElement, page.byId("pdt-dock"))
})

test("client events wait for the hook, then go out in order", async (t) => {
  const page = await load(t)
  page.fromLoader({type: "pdt:client", event: {type: "phx:navigate", n: 1}, dropped: 0})
  page.fromLoader({type: "pdt:client", event: {type: "phx:navigate", n: 2}, dropped: 3}, {origin: "http://evil.test"})
  page.fromLoader({type: "pdt:client", event: null, dropped: 4})

  const bridge = page.join()

  assert.deepEqual(
    bridge.pushed.filter(({event}) => event === "pdt:client").map(({payload}) => payload),
    [
      {event: {type: "phx:navigate", n: 1}, dropped: 0},
      {event: null, dropped: 4},
    ],
  )
})

test("the client buffer before the join is capped", async (t) => {
  const page = await load(t)
  for (let n = 0; n < 60; n++) page.fromLoader({type: "pdt:client", event: {n}, dropped: 0})

  const pushed = page.join().pushed.filter(({event}) => event === "pdt:client")

  assert.equal(pushed.length, 50)
  assert.equal(pushed.at(-1).payload.event.n, 49)
})

test("the hook reports open and visibility on join and on every state", async (t) => {
  const page = await load(t)
  const bridge = page.join()
  page.fromLoader({type: "pdt:state", open: true, dock: "bottom", reserve: true})
  page.document.visibilityState = "hidden"
  page.document.dispatchEvent(new FakeEvent("visibilitychange"))

  assert.deepEqual(
    bridge.pushed.filter(({event}) => event === "pdt:visibility").map(({payload}) => payload),
    [
      {open: false, visible: true},
      {open: true, visible: true},
      {open: true, visible: false},
    ],
  )
  assert.ok(page.html.contains("pdt-joined"))
})

test("a panel that never joins says so after the timeout, and a join clears it", async (t) => {
  const page = await load(t)

  t.mock.timers.tick(7999)
  assert.equal(page.byId("pdt-stalled"), null)
  t.mock.timers.tick(1)
  assert.notEqual(page.byId("pdt-stalled"), null)
  assert.equal(page.document.querySelector(".pdt-tabs").inert, true)

  page.join()
  assert.equal(page.byId("pdt-stalled"), null)
  assert.equal(page.document.querySelector(".pdt-tabs").inert, false)
})

test("the reload breaker stops connecting after repeated loads, Retry starts over", async (t) => {
  const now = Date.now()
  const page = await load(t, {
    setup: ({window}) => window.sessionStorage.setItem("pdt:loads:s1", JSON.stringify([now, now, now])),
  })

  assert.ok(!page.socket.connected)
  assert.notEqual(page.byId("pdt-stalled"), null)

  page.byId("pdt-stalled-retry").click()
  assert.equal(page.window.sessionStorage.getItem("pdt:loads:s1"), null)
  assert.equal(page.window.location.reloads, 1)
})

test("a join forgets this page's recorded loads", async (t) => {
  const page = await load(t)
  assert.notEqual(page.window.sessionStorage.getItem("pdt:loads:s1"), null)

  page.join()

  assert.equal(page.window.sessionStorage.getItem("pdt:loads:s1"), null)
})

// "Copy as Markdown" (ADR 04, 13): the PdtMarkdown hook on #pdt-markdown.
{
  const MARKDOWN = [
    "span",
    {id: "pdt-markdown", "data-pdt-page": "root1"},
    ["button", {id: "pdt-markdown-copy"}, "Copy as Markdown"],
    ["span", {id: "pdt-markdown-result"}],
  ]

  const loadMarkdown = async (t, writes) => {
    const saved = Object.getOwnPropertyDescriptor(globalThis, "navigator")
    Object.defineProperty(globalThis, "navigator", {
      configurable: true,
      value: {clipboard: {writeText: async (text) => writes.push(text)}},
    })
    t.after(() => (saved ? Object.defineProperty(globalThis, "navigator", saved) : delete globalThis.navigator))

    const page = await load(t, {setup: ({document, build}) => document.body.append(build(MARKDOWN))})
    const el = page.byId("pdt-markdown")
    const markdown = Object.create(page.socket.options.hooks.PdtMarkdown)
    markdown.el = el
    markdown.handlers = {}
    markdown.handleEvent = (name, fun) => (markdown.handlers[name] = fun)
    markdown.mounted()
    const result = () => page.byId("pdt-markdown-result").textContent
    const flush = () => new Promise((resolve) => setImmediate(resolve))
    return {page, el, markdown, result, flush}
  }

  test("the pushed Markdown reaches the clipboard as is, and says so", async (t) => {
    const writes = []
    const {markdown, page, result, flush} = await loadMarkdown(t, writes)

    page.byId("pdt-markdown-copy").click()
    markdown.handlers["pdt:markdown"]({text: "# /users\n\n| a |", page: "root1"})
    await flush()

    assert.deepEqual(writes, ["# /users\n\n| a |"])
    assert.equal(result(), "Copied")
  })

  test("the Copied line fades after a few seconds, an error stays", async (t) => {
    const writes = []
    const {markdown, page, result, flush} = await loadMarkdown(t, writes)

    page.byId("pdt-markdown-copy").click()
    markdown.handlers["pdt:markdown"]({text: "# a", page: "root1"})
    await flush()
    assert.equal(result(), "Copied")

    t.mock.timers.tick(3000)
    assert.equal(result(), "")

    markdown.handlers["pdt:markdown"]({error: "gone", page: "root1"})
    t.mock.timers.tick(10000)
    assert.equal(result(), "Copy failed: gone")
  })

  test("an error from the server is shown,a page that no longer matches is dropped", async (t) => {
    const writes = []
    const {markdown, result, flush} = await loadMarkdown(t, writes)

    markdown.handlers["pdt:markdown"]({error: "the page expired, reload it", page: "root1"})
    assert.equal(result(), "Copy failed: the page expired, reload it")

    markdown.handlers["pdt:markdown"]({text: "# old", page: "other"})
    await flush()

    assert.deepEqual(writes, [])
    assert.match(result(), /page changed/)
  })
}
