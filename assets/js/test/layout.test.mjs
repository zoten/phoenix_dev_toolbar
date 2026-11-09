// Unit tests for the panel layout: docks, sizes and persistence (ADR 04).
// Run with `mix test.js` (node --test, Node built-ins only).
import {test} from "node:test"
import assert from "node:assert/strict"

import {
  COLLAPSED_SIZE,
  PAGE_STRIP,
  clampSize,
  defaultSize,
  minSize,
  parseLayout,
  reservedSize,
  serializeLayout,
  sideDock,
  sizeFromPointer,
} from "../layout.mjs"

test("top and bottom default to 45% of the viewport, capped at 520px", () => {
  assert.equal(defaultSize(800, "bottom"), 360)
  assert.equal(defaultSize(2000, "top"), 520)
})

test("left and right default to 40% of the viewport, capped at 480px", () => {
  assert.equal(defaultSize(1000, "left"), 400)
  assert.equal(defaultSize(2000, "right"), 480)
})

test("side docks have a wider minimum than edge docks", () => {
  assert.equal(clampSize(10, 800, "bottom"), minSize("bottom"))
  assert.equal(clampSize(10, 1000, "right"), minSize("right"))
  assert.ok(minSize("right") > minSize("bottom"))
})

test("clamp keeps a page strip and falls back to the default", () => {
  assert.equal(clampSize(300, 800, "bottom"), 300)
  assert.equal(clampSize(5000, 800, "left"), 800 - PAGE_STRIP)
  assert.equal(clampSize(null, 800, "bottom"), defaultSize(800, "bottom"))
})

test("clamp never goes below the minimum, even in a tiny viewport", () => {
  assert.equal(clampSize(300, 100, "bottom"), minSize("bottom"))
})

test("a drag measures from the docked edge", () => {
  assert.equal(sizeFromPointer("bottom", 0, 600, 1000, 800), 200)
  assert.equal(sizeFromPointer("top", 0, 250, 1000, 800), 250)
  assert.equal(sizeFromPointer("left", 300, 0, 1000, 800), 300)
  assert.equal(sizeFromPointer("right", 700, 0, 1000, 800), 300)
})

test("only left and right are side docks", () => {
  assert.deepEqual(["bottom", "top", "left", "right"].map(sideDock), [false, false, true, true])
})

test("reserved space follows the state", () => {
  assert.equal(reservedSize("open", 300), 300)
  assert.equal(reservedSize("collapsed", 300), COLLAPSED_SIZE)
  assert.equal(reservedSize("hidden", 300), 0)
})

test("layout round trips, one size per dock", () => {
  const layout = {dock: "right", sizes: {bottom: 280, right: 420}}
  assert.deepEqual(parseLayout(serializeLayout(layout)), layout)
})

test("the single-size layout is read back as that dock's size", () => {
  assert.deepEqual(parseLayout('{"dock":"bottom","size":280}'), {dock: "bottom", sizes: {bottom: 280}})
})

test("missing, garbled or unknown layouts fall back to the default", () => {
  const fallback = {dock: "bottom", sizes: {}}
  assert.deepEqual(parseLayout(null), fallback)
  assert.deepEqual(parseLayout("{nope"), fallback)
  assert.deepEqual(parseLayout('{"dock":"bottom","size":"big"}'), fallback)
  assert.deepEqual(parseLayout('{"dock":"diagonal","sizes":{"bottom":200,"diagonal":9}}'), {
    dock: "bottom",
    sizes: {bottom: 200},
  })
})
