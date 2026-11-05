// Unit tests for the loader's client event handling (ADR 07).
// Run with `mix test.js` (node --test, Node built-ins only).
import {test} from "node:test"
import assert from "node:assert/strict"

import {
  EVENTS,
  MAX_STRING,
  createLimiter,
  createQueue,
  sanitize,
} from "../client_events.mjs"

test("listens to LiveView's fixed window events only", () => {
  assert.deepEqual(EVENTS, ["phx:page-loading-start", "phx:page-loading-stop", "phx:navigate"])
})

test("sanitize keeps whitelisted scalar fields only", () => {
  const detail = {kind: "patch", to: "/posts", patch: true, secret: "nope", nested: {to: "x"}}

  assert.deepEqual(sanitize("phx:page-loading-start", detail, 1000), {
    type: "phx:page-loading-start",
    at: 1000,
    kind: "patch",
    to: "/posts",
    patch: true,
  })
})

test("sanitize caps strings and ignores objects in whitelisted fields", () => {
  const event = sanitize("phx:navigate", {href: "x".repeat(1000), to: {toString: () => "evil"}}, 1)

  assert.equal(event.href.length, MAX_STRING + 1)
  assert.ok(event.href.endsWith("…"))
  assert.equal(event.to, undefined)
})

test("sanitize survives a missing or non object detail", () => {
  assert.deepEqual(sanitize("phx:navigate", null, 5), {type: "phx:navigate", at: 5})
  assert.deepEqual(sanitize("phx:navigate", "str", 5), {type: "phx:navigate", at: 5})
})

test("sanitize never runs host getters", () => {
  let called = false
  const detail = {}
  Object.defineProperty(detail, "to", {enumerable: true, get: () => { called = true; return "/x" }})

  assert.equal(sanitize("phx:navigate", detail, 1).to, undefined)
  assert.equal(called, false)
})

test("the limiter allows N per second and counts the rest", () => {
  const limiter = createLimiter(2)

  assert.deepEqual([limiter.allow(1000), limiter.allow(1100), limiter.allow(1200)], [true, true, false])
  assert.equal(limiter.dropped(), 1)
  assert.equal(limiter.allow(2000), true)
})

test("the queue buffers until ready, bounded, then sends in order", () => {
  const sent = []
  const queue = createQueue(2, (item) => sent.push(item))

  queue.push("a")
  queue.push("b")
  queue.push("c")
  assert.deepEqual(sent, [])
  assert.equal(queue.dropped(), 1)

  queue.ready()
  queue.push("d")
  assert.deepEqual(sent, ["a", "b", "d"])
})
