// DOM-level tests for the panel's wiring (ADR 04, ADR 07): the postMessage
// bridge to the loader and its origin gate, header clicks, the PdtPanel hook,
// the join timeout and the reload breaker. The real assets/js/panel.js runs
// against a fake DOM (support/fake_dom.mjs) and a fake LiveSocket.
// Run with `mix test.js` (node --test, Node built-ins only).
import {test} from "node:test"
import assert from "node:assert/strict"

import {FakeEvent, FakeWindow, flush, freshImport, installDom, message, stubNavigator} from "./support/fake_dom.mjs"

const ORIGIN = "http://localhost:4000"
const PANEL = new URL("../panel.js", import.meta.url)

// The header of lib/phoenix_dev_toolbar/panel_layout.ex, reduced to what panel.js reads.
const HEADER = [
  "header",
  {class: "pdt-header"},
  ["div", {id: "pdt-bridge", "phx-hook": "PdtPanel", hidden: true}],
  ["span", {class: "pdt-logo"}, "dev toolbar"],
  [
    "div",
    {id: "pdt-tabs", class: "pdt-tabs", role: "tablist", "aria-label": "Toolbar tabs"},
    ["button", {id: "pdt-tab-request", role: "tab"}, "Request"],
    ["button", {id: "pdt-tab-ecto", role: "tab"}, "Ecto"],
    ["button", {id: "pdt-tab-events", role: "tab"}, "Events"],
  ],
  [
    "div",
    {id: "pdt-dock-picker"},
    ["button", {id: "pdt-dock", popovertarget: "pdt-dock-menu", "aria-expanded": "false"}],
    [
      "div",
      {id: "pdt-dock-menu", popover: "auto"},
      ...["bottom", "top", "left", "right"].map((dock) => [
        "button",
        {id: `pdt-dock-${dock}`, "data-pdt-dock": dock, "aria-pressed": "false"},
      ]),
      ["button", {id: "pdt-reserve", "data-pdt-reserve": true, "aria-pressed": "true"}],
      ...["auto", "light", "dark"].map((theme) => [
        "button",
        {id: `pdt-theme-${theme}`, "data-pdt-theme": theme, "aria-pressed": "false"},
      ]),
    ],
  ],
  [
    "span",
    {id: "pdt-header-controls", class: "pdt-header-controls", "phx-update": "ignore"},
    ["button", {id: "pdt-hide", "data-pdt-hide": true}],
    ["button", {id: "pdt-toggle", "data-pdt-toggle": true, "aria-expanded": "false"}],
  ],
  ["span", {id: "pdt-live-status", class: "pdt-sr-only", role: "status", "phx-update": "ignore"}],
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

// A LiveView hook instance on `el`: records its pushes and the handleEvent
// callbacks it registers (`handlers`, by event name).
const hook = (spec, {el, handleEvent} = {}) => {
  const instance = Object.create(spec)
  instance.el = el
  instance.pushed = []
  instance.handlers = {}
  instance.pushEvent = (event, payload) => instance.pushed.push({event, payload})
  instance.handleEvent = handleEvent || ((name, fun) => (instance.handlers[name] = fun))
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

test("the theme sets data-theme on <html> (none for auto) and the pressed option", async (t) => {
  const page = await load(t)
  const root = page.document.documentElement
  const pressed = () => ["auto", "light", "dark"].filter((n) => page.byId(`pdt-theme-${n}`).getAttribute("aria-pressed") === "true")

  page.fromLoader({type: "pdt:state", open: true, dock: "bottom", reserve: true, theme: "dark"})
  assert.equal(root.getAttribute("data-theme"), "dark")
  assert.deepEqual(pressed(), ["dark"])

  page.fromLoader({type: "pdt:state", open: true, dock: "bottom", reserve: true, theme: "neon"})
  assert.equal(root.getAttribute("data-theme"), "dark", "an unknown theme keeps the current one")

  page.fromLoader({type: "pdt:state", open: true, dock: "bottom", reserve: true, theme: "auto"})
  assert.equal(root.getAttribute("data-theme"), null)
  assert.deepEqual(pressed(), ["auto"])
})

test("a theme option posts pdt:theme to the parent page", async (t) => {
  const page = await load(t)

  page.byId("pdt-theme-light").click()

  assert.deepEqual(page.toLoader().map(({data}) => data), [{type: "pdt:theme", theme: "light"}])
})

test("standalone, the theme comes from the stored layout", async (t) => {
  const page = await load(t, {
    framed: false,
    setup: (env) => env.window.localStorage.setItem("pdt:layout", '{"dock":"bottom","sizes":{},"theme":"dark"}'),
  })

  assert.equal(page.document.documentElement.getAttribute("data-theme"), "dark")
  assert.equal(page.byId("pdt-theme-dark").getAttribute("aria-pressed"), "true")
})

test("framed, the stored theme applies at boot, before any message", async (t) => {
  const page = await load(t, {
    setup: (env) => env.window.localStorage.setItem("pdt:layout", '{"dock":"bottom","sizes":{},"theme":"dark"}'),
  })

  assert.equal(page.document.documentElement.getAttribute("data-theme"), "dark")
  page.fromLoader({type: "pdt:state", open: true, dock: "bottom", reserve: true, theme: "light"})
  assert.equal(page.document.documentElement.getAttribute("data-theme"), "light", "pdt:state wins")
})

test("standalone with unreadable storage stays on auto", async (t) => {
  const page = await load(t, {
    framed: false,
    setup: (env) =>
      Object.defineProperty(env.window, "localStorage", {
        get() {
          throw new Error("denied")
        },
      }),
  })

  assert.equal(page.document.documentElement.getAttribute("data-theme"), null)
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

test("the dock menu opens on its button, focuses the pressed option and closes on Escape", async (t) => {
  const page = await load(t)
  const menu = page.byId("pdt-dock-menu")
  page.byId("pdt-dock-left").setAttribute("aria-pressed", "true")

  assert.equal(menu.matches(":popover-open"), false)
  page.byId("pdt-dock").click()
  assert.equal(menu.matches(":popover-open"), true)
  assert.equal(page.byId("pdt-dock").getAttribute("aria-expanded"), "true")
  assert.equal(page.document.activeElement, page.byId("pdt-dock-left"))

  page.byId("pdt-dock-top").dispatchEvent(new FakeEvent("keydown", {key: "Escape"}))
  assert.equal(menu.matches(":popover-open"), false)
  assert.equal(page.byId("pdt-dock").getAttribute("aria-expanded"), "false")
  assert.equal(page.document.activeElement, page.byId("pdt-dock"))
})

test("Escape refocuses the dock button when the browser left focus on the body", async (t) => {
  const page = await load(t)
  page.document.popoverReturnsFocus = false

  page.byId("pdt-dock").click()
  page.byId("pdt-dock-top").dispatchEvent(new FakeEvent("keydown", {key: "Escape"}))
  assert.equal(page.document.activeElement, page.byId("pdt-dock"))
})

test("the dock menu opens on the first option when none is pressed", async (t) => {
  const page = await load(t)

  page.byId("pdt-dock").click()
  assert.equal(page.document.activeElement, page.byId("pdt-dock-bottom"))
})

test("a second click on the button closes the dock menu", async (t) => {
  const page = await load(t)

  page.byId("pdt-dock").click()
  page.byId("pdt-dock").click()
  assert.equal(page.byId("pdt-dock-menu").matches(":popover-open"), false)
  assert.equal(page.byId("pdt-dock").getAttribute("aria-expanded"), "false")
})

test("an outside click light dismisses the dock menu, a click inside does not", async (t) => {
  const page = await load(t)
  const menu = page.byId("pdt-dock-menu")

  page.byId("pdt-dock").click()
  page.byId("pdt-reserve").click()
  assert.equal(menu.matches(":popover-open"), true)
  page.byId("pdt-tab-ecto").click()
  assert.equal(menu.matches(":popover-open"), false)
})

test("picking a dock closes the menu and refocuses the button", async (t) => {
  const page = await load(t)

  page.byId("pdt-dock").click()
  page.byId("pdt-dock-right").click()
  assert.equal(page.byId("pdt-dock-menu").matches(":popover-open"), false)
  assert.equal(page.document.activeElement, page.byId("pdt-dock"))
})

test("collapsing the panel closes the dock menu", async (t) => {
  const page = await load(t)

  page.fromLoader({type: "pdt:state", open: true, dock: "bottom", reserve: true})
  page.byId("pdt-dock").click()
  page.fromLoader({type: "pdt:state", open: false, dock: "bottom", reserve: true})
  assert.equal(page.byId("pdt-dock-menu").matches(":popover-open"), false)
})

test("without the Popover API the panel still loads and nothing throws", async (t) => {
  const page = await load(t)
  const menu = page.byId("pdt-dock-menu")
  menu.showPopover = undefined
  menu.hidePopover = undefined

  page.fromLoader({type: "pdt:state", open: false, dock: "bottom", reserve: true})
  page.byId("pdt-dock-top").dispatchEvent(new FakeEvent("focusout", {relatedTarget: page.byId("pdt-toggle")}))
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
    stubNavigator(t, {clipboard: {writeText: async (text) => writes.push(text)}})

    const page = await load(t, {setup: ({document, build}) => document.body.append(build(MARKDOWN))})
    const el = page.byId("pdt-markdown")
    const markdown = hook(page.socket.options.hooks.PdtMarkdown, {el})
    markdown.mounted()
    const result = () => page.byId("pdt-markdown-result").textContent
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

// Keyboard focus (ADR 04): a re-rendered button gets its focus back.
{
  const keepFocus = (fallback) => ["button", {id: "pdt-run", "data-pdt-keep-focus": fallback}, "Run"]
  const loadFocus = (t, fallback = "") =>
    load(t, {setup: ({document, build}) => document.body.append(build(keepFocus(fallback)), build(["button", {id: "other"}]))})

  // What the browser does when a focused element is re-inserted: it blurs, the
  // focusout has no relatedTarget.
  const blur = (page, el) => {
    page.document.activeElement = null
    el.dispatchEvent(new FakeEvent("focusout", {relatedTarget: null}))
  }

  test("a keep-focus button that blurs on its own gets the focus back on the next frame", async (t) => {
    const page = await loadFocus(t)
    const run = page.byId("pdt-run")
    run.focus()

    blur(page, run)
    assert.equal(page.document.activeElement, null)
    page.flushFrames()

    assert.equal(page.document.activeElement, run)
  })

  test("a keep-focus button that was replaced hands the focus to the element it names", async (t) => {
    const page = await loadFocus(t, "pdt-run-next")
    const run = page.byId("pdt-run")
    const next = page.build(["button", {id: "pdt-run-next"}])
    run.focus()

    blur(page, run)
    run.remove()
    page.document.body.append(next)
    page.flushFrames()

    assert.equal(page.document.activeElement, next)
  })

  test("the focus stays where the user put it: a click elsewhere, a focus move or a plain button", async (t) => {
    const page = await loadFocus(t)
    const run = page.byId("pdt-run")
    const other = page.byId("other")

    run.focus()
    other.dispatchEvent(new FakeEvent("pointerdown"))
    blur(page, run)
    page.flushFrames()
    assert.equal(page.document.activeElement, null, "clicked elsewhere")

    run.dispatchEvent(new FakeEvent("keydown", {key: "Tab"}))
    run.dispatchEvent(new FakeEvent("focusout", {relatedTarget: other}))
    page.flushFrames()
    assert.equal(page.document.activeElement, null, "focus moved to another element")

    blur(page, run)
    other.focus()
    page.flushFrames()
    assert.equal(page.document.activeElement, other, "something else took the focus meanwhile")

    other.dispatchEvent(new FakeEvent("pointerdown"))
    run.dispatchEvent(new FakeEvent("keydown", {key: "Enter"}))
    run.focus()
    blur(page, run)
    page.flushFrames()
    assert.equal(page.document.activeElement, run, "a key press after the click makes it a keyboard user again")

    other.dispatchEvent(new FakeEvent("focusout", {relatedTarget: null}))
    page.document.activeElement = null
    page.flushFrames()
    assert.equal(page.document.activeElement, null, "a button without data-pdt-keep-focus")
  })
}

test("arrow keys move between the tabs, wrap around and select the one reached", async (t) => {
  const page = await load(t)
  const request = page.byId("pdt-tab-request")
  const ecto = page.byId("pdt-tab-ecto")
  const press = (el, key) => {
    const event = new FakeEvent("keydown", {key})
    el.dispatchEvent(event)
    return event
  }

  assert.equal(press(request, "ArrowRight").defaultPrevented, true)
  assert.equal(page.document.activeElement, ecto)
  assert.deepEqual(page.toLoader().map(({data}) => data), [{type: "pdt:open"}], "selecting a tab opens the panel")

  const events = page.byId("pdt-tab-events")
  press(ecto, "ArrowRight")
  assert.equal(page.document.activeElement, events)
  press(events, "ArrowRight")
  assert.equal(page.document.activeElement, request, "wraps to the first")

  press(request, "ArrowLeft")
  assert.equal(page.document.activeElement, events, "wraps to the last")
  assert.equal(page.toLoader().length, 4)

  const other = press(ecto, "ArrowDown")
  assert.equal(other.defaultPrevented, false)
  assert.equal(page.toLoader().length, 4, "other keys are left alone")

  assert.equal(press(page.byId("pdt-toggle"), "ArrowRight").defaultPrevented, false, "only on tabs")
})

test("Home and End select the first and the last tab", async (t) => {
  const page = await load(t)
  const request = page.byId("pdt-tab-request")
  const last = page.byId("pdt-tab-events")

  request.dispatchEvent(new FakeEvent("keydown", {key: "End"}))
  assert.equal(page.document.activeElement, last)
  const home = new FakeEvent("keydown", {key: "Home"})
  last.dispatchEvent(home)
  assert.equal(home.defaultPrevented, true)
  assert.equal(page.document.activeElement, request)
  assert.equal(page.toLoader().length, 2, "each selects the tab")
})

test("the toggle's aria-expanded follows the loader's state", async (t) => {
  const page = await load(t)
  const toggle = page.byId("pdt-toggle")

  page.fromLoader({type: "pdt:state", open: true, dock: "bottom", reserve: true})
  assert.equal(toggle.getAttribute("aria-expanded"), "true")
  page.fromLoader({type: "pdt:state", open: false, dock: "bottom", reserve: true})
  assert.equal(toggle.getAttribute("aria-expanded"), "false")
})

test("the dock menu closes when focus leaves the picker, not when it moves inside", async (t) => {
  const page = await load(t)
  const menu = page.byId("pdt-dock-menu")
  const out = (from, to) => from.dispatchEvent(new FakeEvent("focusout", {relatedTarget: to}))

  page.byId("pdt-dock").click()
  out(page.byId("pdt-dock-top"), page.byId("pdt-dock-left"))
  assert.equal(menu.matches(":popover-open"), true, "inside the picker")
  out(page.byId("pdt-dock-top"), null)
  assert.equal(menu.matches(":popover-open"), true, "no related target: the window lost focus")
  page.byId("pdt-toggle").focus()
  out(page.byId("pdt-dock-top"), page.byId("pdt-toggle"))
  assert.equal(menu.matches(":popover-open"), false)
  assert.equal(page.byId("pdt-dock").getAttribute("aria-expanded"), "false")
  assert.equal(page.document.activeElement, page.byId("pdt-toggle"), "no refocus")
})

test("pdt:focus from the parent focuses the toggle, from elsewhere it does nothing", async (t) => {
  const page = await load(t)

  page.fromLoader({type: "pdt:focus"}, {source: new FakeWindow({origin: ORIGIN})})
  page.fromLoader({type: "pdt:focus"}, {origin: "http://evil.test"})
  assert.notEqual(page.document.activeElement, page.byId("pdt-toggle"))

  page.fromLoader({type: "pdt:focus"})
  assert.equal(page.document.activeElement, page.byId("pdt-toggle"))
})

test("the live status announces a lost connection and clears the reconnect", async (t) => {
  const page = await load(t)
  const bridge = page.join()
  const status = page.byId("pdt-live-status")

  bridge.disconnected()
  assert.match(status.textContent, /^Toolbar disconnected/)
  bridge.reconnected()
  assert.equal(status.textContent, "Toolbar reconnected")
  t.mock.timers.tick(3000)
  assert.equal(status.textContent, "")
})

// The collapsed bar's "+N" badge (ADR 04): the PdtSummaryMore hook on #pdt-summary-more.
{
  const observers = {resize: [], mutation: []}
  class Observer {
    constructor(kind, callback) {
      Object.assign(this, {callback, disconnected: false})
      observers[kind].push(this)
    }

    observe(target) {
      this.target = target
    }

    disconnect() {
      this.disconnected = true
    }
  }

  const loadSummary = async (t, {rows, side = false}) => {
    globalThis.ResizeObserver = class extends Observer {
      constructor(callback) {
        super("resize", callback)
      }
    }
    globalThis.MutationObserver = class extends Observer {
      constructor(callback) {
        super("mutation", callback)
      }
    }
    observers.resize = []
    observers.mutation = []
    t.after(() => {
      delete globalThis.ResizeObserver
      delete globalThis.MutationObserver
    })

    const page = await load(t, {
      setup: ({document, build}) =>
        document.body.append(
          build(["div", {id: "pdt-summary"}, ...rows.map(() => ["span", {class: "pdt-badge"}])]),
          build(["button", {id: "pdt-summary-more", hidden: true}]),
        ),
    })
    const summary = page.byId("pdt-summary")
    const place = (positions) =>
      summary.children.forEach((badge, i) => (badge[side ? "offsetLeft" : "offsetTop"] = positions[i]))
    place(rows)
    if (side) page.fromLoader({type: "pdt:state", open: false, dock: "left", reserve: true})

    const more = page.byId("pdt-summary-more")
    const badge = hook(page.socket.options.hooks.PdtSummaryMore, {el: more})
    badge.mounted()
    return {page, more, summary, badge, place}
  }

  test("the badge counts the summary badges that wrapped out of the collapsed bar", async (t) => {
    const {more, summary} = await loadSummary(t, {rows: [0, 0, 22, 22, 44]})

    assert.equal(more.textContent, "+3")
    assert.equal(more.hidden, false)
    assert.equal(observers.resize[0].target, summary)
    assert.equal(observers.mutation[0].target, summary)
  })

  test("the badge hides when everything fits on one row", async (t) => {
    const {more} = await loadSummary(t, {rows: [0, 0, 0]})

    assert.equal(more.textContent, "+0")
    assert.equal(more.hidden, true)
  })

  test("the badge recounts when the summary resizes or changes, and not when the panel is open", async (t) => {
    const {page, more, place} = await loadSummary(t, {rows: [0, 0, 0]})

    place([0, 0, 22])
    observers.mutation[0].callback()
    assert.equal(more.textContent, "+1")

    place([0, 22, 44])
    observers.resize[0].callback()
    assert.equal(more.textContent, "+2")

    page.fromLoader({type: "pdt:state", open: true, dock: "bottom", reserve: true})
    observers.resize[0].callback()
    assert.equal(more.textContent, "+0", "open, the summary shows every badge")
    assert.equal(more.hidden, true)
  })

  test("on a side dock the wrapped badges are the columns to the left", async (t) => {
    const {more} = await loadSummary(t, {rows: [100, 100, 60, 20], side: true})

    assert.equal(more.textContent, "+2")
    assert.equal(more.hidden, false)
  })

  test("destroying the badge stops both observers", async (t) => {
    const {badge} = await loadSummary(t, {rows: [0]})

    badge.destroyed()

    assert.ok(observers.resize[0].disconnected)
    assert.ok(observers.mutation[0].disconnected)
  })
}

// The Ecto tab's Copy (ADR 08): the PdtExport hook on #pdt-ecto-export.
{
  const FORM = [
    "form",
    {id: "pdt-ecto-export", "data-pdt-page": "root1"},
    ["input", {id: "pdt-export-choice", type: "checkbox"}],
    ["button", {id: "pdt-export-copy"}, "Copy"],
    ["span", {id: "pdt-export-result"}],
  ]

  // `secure` gives the browser's async clipboard (ClipboardItem), else only the
  // text API is missing too: the pre Clipboard API execCopy path, which a fake
  // document cannot grant (no execCommand), so exports are held.
  const loadExport = async (t, {secure = true} = {}) => {
    const copied = []
    if (secure) {
      globalThis.ClipboardItem = class {
        constructor(data) {
          this.data = data
        }
      }
      t.after(() => delete globalThis.ClipboardItem)
    }
    stubNavigator(t, {
      clipboard: secure
        ? {write: async ([item]) => copied.push(await (await item.data["text/plain"]).text())}
        : undefined,
    })

    const page = await load(t, {setup: ({document, build}) => document.body.append(build(FORM))})
    const form = page.byId("pdt-ecto-export")
    const exporter = hook(page.socket.options.hooks.PdtExport, {el: form})
    exporter.mounted()
    const result = () => page.byId("pdt-export-result").textContent
    const click = (id = "pdt-export-copy") => {
      const event = new FakeEvent("click", {button: 0})
      page.byId(id).dispatchEvent(event)
      return event
    }
    const arrive = (data) => exporter.handlers["pdt:export"](data)
    return {page, form, exporter, copied, result, click, arrive}
  }

  test("Copy claims the clipboard in the click and the pushed export fills it", async (t) => {
    const {copied, result, click, arrive} = await loadExport(t)

    const event = click()
    assert.equal(result(), "Copying…")
    assert.equal(event.defaultPrevented, false, "the click goes on: the export is requested by the form")

    arrive({payload: {count: 1}, page: "root1"})
    await flush()

    assert.deepEqual(copied, [JSON.stringify({count: 1}, null, 2)])
    assert.equal(result(), "Copied")
  })

  test("clicks outside the Copy button are ignored", async (t) => {
    const {result, click, form} = await loadExport(t)

    click("pdt-export-choice")
    form.dispatchEvent(new FakeEvent("click", {button: 0}))

    assert.equal(result(), "")
  })

  test("an export for another page is not copied", async (t) => {
    const {copied, result, click, arrive} = await loadExport(t)

    click()
    arrive({payload: {}, page: "root2"})
    await flush()

    assert.deepEqual(copied, [])
    assert.match(result(), /page changed/)
  })

  test("the form showing another page settles the pending copy, an unchanged one does not", async (t) => {
    const {form, exporter, result, click} = await loadExport(t)
    click()

    exporter.updated()
    assert.equal(result(), "Copying…", "same page")

    form.setAttribute("data-pdt-page", "root2")
    exporter.updated()
    assert.match(result(), /page changed/)
  })

  test("without a secure context the export is held and the next click copies it or says why it cannot", async (t) => {
    const {result, click, arrive} = await loadExport(t, {secure: false})

    assert.equal(click().defaultPrevented, false)
    arrive({payload: [1], page: "root1"})
    assert.equal(result(), "Export ready: click Copy again")

    const again = click()
    assert.equal(again.defaultPrevented, true, "the click does not request another export")
    assert.equal(again.stopped, true)
    assert.equal(result(), "Copy failed: use Download", "this fake page refuses the copy command")
  })

  test("a new choice in the form drops the held export", async (t) => {
    const {form, result, click, arrive} = await loadExport(t, {secure: false})
    click()
    arrive({payload: [1], page: "root1"})

    form.dispatchEvent(new FakeEvent("change"))

    assert.equal(click().defaultPrevented, false, "a fresh export is requested")
  })

  test("destroying the hook removes its listeners", async (t) => {
    const {exporter, result, click} = await loadExport(t)

    exporter.destroyed()
    click()

    assert.equal(result(), "")
  })
}

test("shortcut: a match with focus inside the panel posts a toggle, and the hide button shows the combo", async (t) => {
  const page = await load(t)
  const press = (init = {}) => {
    const event = new FakeEvent("keydown", {code: "KeyD", ctrlKey: true, shiftKey: true, target: page.document.body, ...init})
    page.document.dispatchEvent(event)
    return event
  }
  const toggles = () => page.toLoader().filter(({data}) => data.type === "pdt:toggle").length

  press()
  assert.equal(toggles(), 0, "no shortcut known yet")

  page.fromLoader({type: "pdt:state", open: true, dock: "bottom", reserve: true, shortcut: "ctrl+shift+d"})
  assert.equal(page.byId("pdt-hide").title, "Hide (Ctrl+Shift+D)")
  assert.ok(press().defaultPrevented)
  assert.equal(toggles(), 1)

  for (const init of [{code: "KeyE"}, {altKey: true}, {repeat: true}, {isComposing: true}, {target: page.document.createElement("textarea")}]) {
    assert.ok(!press(init).defaultPrevented, Object.keys(init).join())
  }
  assert.equal(toggles(), 1)

  page.fromLoader({type: "pdt:state", open: true, dock: "bottom", reserve: true, shortcut: null})
  press()
  assert.equal(toggles(), 1, "the shortcut was dropped")
  assert.equal(page.byId("pdt-hide").title, "Hide")
})
