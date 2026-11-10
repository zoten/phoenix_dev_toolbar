// DOM-level tests for the loader's wiring (ADR 04, ADR 07): mount, the
// postMessage bridge and its origin gate, state, docks, client events. The
// real assets/js/loader.js runs against a fake DOM (support/fake_dom.mjs).
// Run with `mix test.js` (node --test, Node built-ins only).
import {test} from "node:test"
import assert from "node:assert/strict"

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

  assert.ok(page.posted().length >= 2)
  page.posted().forEach(({targetOrigin}) => assert.equal(targetOrigin, ORIGIN))
  assert.deepEqual(page.lastState(), {type: "pdt:state", open: true, dock: "bottom", reserve: true})
})

test("toggle, hide and the corner pill move between the three states", async (t) => {
  const page = await load(t)
  const state = () => page.window.localStorage.getItem("pdt:state")

  page.fromPanel({type: "pdt:toggle"})
  assert.equal(state(), "open")
  assert.equal(page.host.style.height, page.host.style.getPropertyValue("--pdt-extent"))

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

  assert.doesNotThrow(() => page.window.dispatchEvent(new FakeEvent("phx:navigate", {detail})))
})

test("a burst past the rate limit reports its drops a second later", async (t) => {
  const page = await load(t)
  page.frame.dispatchEvent(new FakeEvent("load"))
  for (let i = 0; i < 100; i++) page.window.dispatchEvent(new FakeEvent("phx:navigate", {detail: {}}))

  t.mock.timers.tick(1000)
  const report = page.posted().filter(({data}) => data.type === "pdt:client").at(-1).data

  assert.equal(report.event, null)
  assert.ok(report.dropped > 0)
})

test("the keyboard resizes the open panel and stores its size", async (t) => {
  const page = await load(t)
  page.fromPanel({type: "pdt:open"})
  const handle = page.root.querySelector("div")
  const before = Number(handle.getAttribute("aria-valuenow"))

  handle.dispatchEvent(new FakeEvent("keydown", {key: "ArrowUp", shiftKey: false}))

  assert.equal(Number(handle.getAttribute("aria-valuenow")), before + 16)
  assert.equal(JSON.parse(page.window.localStorage.getItem("pdt:layout")).sizes.bottom, before + 16)
})
