// Unit tests for the element inspector's pure helpers (ADR 16) on the fake DOM.
import {test} from "node:test"
import assert from "node:assert/strict"

import {MAX_FRAMES, MAX_NODES, nodeBudget, MAX_STRING_BYTES, outlineBox, resolve, truncate} from "../inspect.mjs"
import {installDom} from "./support/fake_dom.mjs"

const open = (name, loc = "lib/x.ex:12") => ["#comment", ` <${name}> ${loc} (demo) `]
const close = (name) => ["#comment", ` </${name}> `]
const caller = (loc = "lib/y.ex:34") => ["#comment", ` @caller ${loc} (demo) `]

// Builds `children` inside a LiveView root in <body>; returns the page and the
// element with id "target".
const page = (t, ...children) => {
  const env = installDom()
  t.after(env.restore)
  const view = env.build(["div", {id: "phx-F1", "data-phx-session": "s"}, ...children])
  env.document.body.append(view)
  return {...env, view, target: env.document.getElementById("target")}
}

test("an element outside any component has no frames", (t) => {
  const {target} = page(t, ["button", {id: "target"}])

  const inspected = resolve(target)

  assert.deepEqual(inspected.frames, [])
  assert.equal(inspected.caller, null)
  assert.equal(inspected.tag, "button")
  assert.equal(inspected.root, "phx-F1")
})

test("an open component annotation before the element is a frame", (t) => {
  const {target} = page(t, open("Demo.Core.button"), ["button", {id: "target"}], close("Demo.Core.button"))

  assert.deepEqual(resolve(target).frames, [{name: "Demo.Core.button", file: "lib/x.ex", line: 12}])
})

test("a component closed before the element is not a frame", (t) => {
  const {target} = page(t, open("Demo.Core.icon"), ["svg"], close("Demo.Core.icon"), ["button", {id: "target"}])

  assert.deepEqual(resolve(target).frames, [])
})

test("frames are innermost first, collected across ancestor levels", (t) => {
  const {target} = page(
    t,
    open("Demo.Outer.card", "lib/outer.ex:5"),
    ["section", {}, open("Demo.Inner.button", "lib/inner.ex:9"), ["button", {id: "target"}], close("Demo.Inner.button")],
    close("Demo.Outer.card"),
  )

  assert.deepEqual(
    resolve(target).frames.map(({name}) => name),
    ["Demo.Inner.button", "Demo.Outer.card"],
  )
})

test("a sibling closed component does not hide an enclosing open one with the same name", (t) => {
  const {target} = page(
    t,
    open("Demo.Core.box", "lib/a.ex:1"),
    open("Demo.Core.box", "lib/b.ex:2"),
    ["i"],
    close("Demo.Core.box"),
    ["button", {id: "target"}],
  )

  assert.deepEqual(resolve(target).frames, [{name: "Demo.Core.box", file: "lib/a.ex", line: 1}])
})

test("the caller annotation before the innermost open frame is its caller", (t) => {
  const {target} = page(t, caller("lib/page.ex:34"), open("Demo.Core.button"), ["button", {id: "target"}])

  assert.deepEqual(resolve(target).caller, {file: "lib/page.ex", line: 34})
})

test("a frame without a caller annotation has no caller", (t) => {
  const {target} = page(t, open("Demo.Core.button"), ["button", {id: "target"}])

  assert.equal(resolve(target).caller, null)
})

test("slot annotations are skipped", (t) => {
  const {target} = page(t, open("Demo.Core.modal"), ["#comment", " <:inner_block> lib/x.ex:3 (demo) "], ["button", {id: "target"}])

  assert.deepEqual(
    resolve(target).frames.map(({name}) => name),
    ["Demo.Core.modal"],
  )
})

test("the app suffix is optional", (t) => {
  const {target} = page(t, ["#comment", " <Demo.Core.button> lib/x.ex:12 "], ["button", {id: "target"}])

  assert.deepEqual(resolve(target).frames, [{name: "Demo.Core.button", file: "lib/x.ex", line: 12}])
})

test("the binding is the closest phx-click ancestor with its target", (t) => {
  const {target} = page(t, ["button", {"phx-click": "save", "phx-target": "#form"}, ["span", {id: "target"}]])

  assert.deepEqual(resolve(target).binding, {event: "phx-click", name: "save", target: "#form"})
})

test("a form binding is found for a field inside it", (t) => {
  const {target} = page(t, ["form", {"phx-submit": "go"}, ["input", {id: "target"}]])

  assert.deepEqual(resolve(target).binding, {event: "phx-submit", name: "go", target: null})
})

test("no binding on the path gives null", (t) => {
  const {target} = page(t, ["p", {id: "target"}])

  assert.equal(resolve(target).binding, null)
})

test("a binding outside the LiveView root is ignored", (t) => {
  const env = installDom()
  t.after(env.restore)
  const outer = env.build(["div", {"phx-click": "outer"}, ["div", {"data-phx-session": "s", id: "phx-F1"}, ["p", {id: "target"}]]])
  env.document.body.append(outer)

  assert.equal(resolve(env.document.getElementById("target")).binding, null)
})

test("root, cid and the tag line come from data-phx attributes", (t) => {
  const {target} = page(t, ["div", {"data-phx-component": "3"}, ["p", {id: "target", "data-phx-loc": "42"}]])

  const inspected = resolve(target)

  assert.equal(inspected.cid, 3)
  assert.equal(inspected.tag_line, 42)
})

test("a dead render has no root and no cid", (t) => {
  const env = installDom()
  t.after(env.restore)
  env.document.body.append(env.build(["p", {id: "target"}]))

  const inspected = resolve(env.document.getElementById("target"))

  assert.equal(inspected.root, null)
  assert.equal(inspected.cid, null)
})

test("garbage integers become null", (t) => {
  const {target} = page(t, ["div", {"data-phx-component": "-1"}, ["p", {id: "target", "data-phx-loc": "99999999999"}]])

  const inspected = resolve(target)

  assert.equal(inspected.cid, null)
  assert.equal(inspected.tag_line, null)
})

test("strings are truncated to the byte cap", (t) => {
  const {target} = page(t, ["button", {id: "target", "phx-click": "é".repeat(600)}])

  const name = resolve(target).binding.name

  assert.ok(new TextEncoder().encode(name).length <= MAX_STRING_BYTES)
  assert.ok(name.length > 0)
})

test("frames are capped", (t) => {
  const comments = Array.from({length: MAX_FRAMES + 10}, (_, i) => open(`Demo.C${i}.f`))
  const {target} = page(t, ...comments, ["button", {id: "target"}])

  assert.equal(resolve(target).frames.length, MAX_FRAMES)
})

test("the walk visits at most MAX_NODES nodes", (t) => {
  const filler = Array.from({length: MAX_NODES + 50}, () => ["#comment", " noise "])
  const {target} = page(t, open("Demo.Far.away"), ...filler, ["button", {id: "target"}])

  assert.deepEqual(resolve(target).frames, [])
})

test("outlineBox is the element's viewport rect", (t) => {
  const {target} = page(t, ["button", {id: "target"}])
  target.rect = {left: 10, top: 20, width: 30, height: 40, right: 40, bottom: 60}

  assert.deepEqual(outlineBox(target), {left: 10, top: 20, width: 30, height: 40})
})

test("truncating emoji never leaves a lone surrogate", () => {
  const out = truncate("😀".repeat(300))

  assert.ok(!/[\uD800-\uDBFF]$/.test(out))
  assert.ok(new TextEncoder().encode(out).length <= MAX_STRING_BYTES)
  const odd = truncate("a" + "😀".repeat(300))
  assert.ok(!/[\uD800-\uDBFF]$/.test(odd))
})

test("whitespace text nodes between the comments and the element are skipped", (t) => {
  const {target} = page(
    t,
    caller(),
    "\n  ",
    open("Demo.Core.button"),
    "\n  ",
    ["button", {id: "target"}],
    "\n",
    close("Demo.Core.button"),
  )

  const inspected = resolve(target)

  assert.deepEqual(inspected.frames.map(({name}) => name), ["Demo.Core.button"])
  assert.deepEqual(inspected.caller, {file: "lib/y.ex", line: 34})
})

// A parent LiveView whose component holds a nested live_render.
const nested = (t) => {
  const env = installDom()
  t.after(env.restore)
  const parent = env.build([
    "div",
    {id: "phx-P", "data-phx-session": "p"},
    open("Demo.Parent.card", "lib/parent.ex:1"),
    [
      "section",
      {"data-phx-component": "1"},
      [
        "div",
        {id: "phx-C", "data-phx-session": "c"},
        open("Demo.Child.button", "lib/child.ex:2"),
        ["button", {id: "target", "data-phx-component": "9"}],
        ["input", {id: "plain"}],
      ],
    ],
  ])
  env.document.body.append(parent)
  return env
}

test("a component outside the LiveView root is not the element's cid", (t) => {
  const env = nested(t)

  assert.equal(resolve(env.document.getElementById("plain")).cid, null)
  assert.equal(resolve(env.document.getElementById("plain")).root, "phx-C")
  assert.equal(resolve(env.document.getElementById("target")).cid, 9)
})

test("the frame walk stops at the nested LiveView root", (t) => {
  const env = nested(t)

  const {frames} = resolve(env.document.getElementById("plain"))

  assert.deepEqual(frames.map(({name}) => name), ["Demo.Child.button"])
})

test("a picked cell in row 150 of a table keeps its frames with the default budget", (t) => {
  const row = (i) => ["tr", {}, ["td", {}, ["#comment", " noise "]], ["td", {}]]
  const rows = Array.from({length: 150}, (_, i) => row(i))
  const {target} = page(t, open("Demo.Core.table"), ["table", {}, ["tbody", {}, ...rows, ["tr", {}, ["td", {id: "target"}]]]])

  const inspected = resolve(target)

  assert.deepEqual(inspected.frames.map(({name}) => name), ["Demo.Core.table"])
  assert.equal(inspected.truncated, false)
})

test("truncated is true when the budget ran out before the root, false otherwise", (t) => {
  const filler = Array.from({length: 120}, () => ["#comment", " noise "])
  const {target} = page(t, open("Demo.Core.button"), ...filler, ["button", {id: "target"}])

  const small = resolve(target, {maxNodes: 50})
  assert.deepEqual(small.frames, [])
  assert.equal(small.truncated, true)
  assert.equal(resolve(target, {maxNodes: 500}).truncated, false)
})

test("nodeBudget accepts integers from 50 to 10000, else the default", () => {
  assert.equal(nodeBudget("50"), 50)
  assert.equal(nodeBudget("10000"), 10_000)
  for (const bad of [undefined, "", "49", "10001", "abc", "1.5", "-5", "5e2"]) assert.equal(nodeBudget(bad), MAX_NODES, String(bad))
})
