// Unit tests for the panel's reload breaker (ADR 04).
// Run with `mix test.js` (node --test, Node built-ins only).
import {test} from "node:test"
import assert from "node:assert/strict"

import {MAX_LOADS, WINDOW_MS, parse, record, tripped} from "../reloads.mjs"

test("trips on the load after MAX_LOADS within the window", () => {
  let times = []
  for (let n = 0; n < MAX_LOADS; n++) times = record(times, 1000 + n)
  assert.equal(tripped(times), false)
  assert.equal(tripped(record(times, 2000)), true)
})

test("loads older than the window are forgotten", () => {
  const times = [0, 1, 2]
  assert.deepEqual(record(times, WINDOW_MS + 5), [WINDOW_MS + 5])
  assert.equal(tripped(record(times, WINDOW_MS + 5)), false)
})

test("a stored list that is not one counts as empty", () => {
  assert.deepEqual(parse(null), [])
  assert.deepEqual(parse("{"), [])
  assert.deepEqual(parse('{"a":1}'), [])
  assert.deepEqual(parse('[1,"x",2]'), [1, 2])
})
