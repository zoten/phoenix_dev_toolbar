// Unit tests for the summary bar's overflow count (ADR 04).
// Run with `mix test.js` (node --test, Node built-ins only).
import {test} from "node:test"
import assert from "node:assert/strict"

import {countWrapped} from "../summary.mjs"

test("no badges, or all on one row: nothing hidden", () => {
  assert.equal(countWrapped([]), 0)
  assert.equal(countWrapped([0, 0, 0]), 0)
})

test("counts the badges wrapped below the first row", () => {
  assert.equal(countWrapped([0, 0, 26, 26, 52]), 3)
})

test("sideways strip: negated column offsets count the wrapped columns", () => {
  // vertical-rl wraps columns leftwards: the first column has the largest offsetLeft.
  assert.equal(countWrapped([38, 38, 12, 12, -14].map((left) => -left)), 3)
})
