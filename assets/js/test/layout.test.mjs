// Unit tests for the panel layout: sizes and persistence (ADR 04).
// Run with `mix test.js` (node --test, Node built-ins only).
import {test} from "node:test"
import assert from "node:assert/strict"

import {
  COLLAPSED_SIZE,
  MIN_SIZE,
  PAGE_STRIP,
  clampSize,
  defaultSize,
  parseLayout,
  reservedSize,
  serializeLayout,
} from "../layout.mjs"

test("default size is 45% of the viewport, capped at 520px", () => {
  assert.equal(defaultSize(800), 360)
  assert.equal(defaultSize(2000), 520)
})

test("clamp keeps a size inside the viewport, leaving a page strip", () => {
  assert.equal(clampSize(300, 800), 300)
  assert.equal(clampSize(10, 800), MIN_SIZE)
  assert.equal(clampSize(5000, 800), 800 - PAGE_STRIP)
})

test("clamp falls back to the default size when none is stored", () => {
  assert.equal(clampSize(null, 800), defaultSize(800))
})

test("clamp never goes below the minimum, even in a tiny viewport", () => {
  assert.equal(clampSize(300, 100), MIN_SIZE)
})

test("reserved space follows the state", () => {
  assert.equal(reservedSize("open", 300), 300)
  assert.equal(reservedSize("collapsed", 300), COLLAPSED_SIZE)
  assert.equal(reservedSize("hidden", 300), 0)
})

test("layout round trips", () => {
  const layout = {dock: "bottom", size: 280}
  assert.deepEqual(parseLayout(serializeLayout(layout)), layout)
})

test("missing, garbled or unknown layouts fall back to the default", () => {
  const fallback = {dock: "bottom", size: null}
  assert.deepEqual(parseLayout(null), fallback)
  assert.deepEqual(parseLayout("{nope"), fallback)
  assert.deepEqual(parseLayout('{"dock":"left","size":200}'), fallback)
  assert.deepEqual(parseLayout('{"dock":"bottom","size":"big"}'), fallback)
})
