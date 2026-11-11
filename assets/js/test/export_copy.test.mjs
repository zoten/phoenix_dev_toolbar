// Unit tests for the Ecto tab's Copy (ADR 08): clipboard, timers and the
// result line are fakes. Run with `mix test.js` (node --test, Node built-ins only).
import {test} from "node:test"
import assert from "node:assert/strict"

import {EXPORT_WAIT_MS, NO_EXPORT, PAGE_CHANGED, createExportCopy} from "../export_copy.mjs"

class FakeItem {
  constructor(data) {
    this.data = data
  }
}

class FakeBlob {
  constructor(parts) {
    this.text = parts.join("")
  }
}

// A secure context when `item` is true: write() settles with the promised text,
// as the browser does.
const setup = ({item = true, writeText = false, execCopy = () => false} = {}) => {
  const said = []
  const copied = []
  const timers = new Map()
  let nextTimer = 0
  const clipboard = {
    write: item
      ? ([entry]) =>
          entry.data["text/plain"].then((blob) => {
            copied.push(blob.text)
          })
      : undefined,
    writeText: writeText ? async (text) => copied.push(text) : undefined,
  }
  const env = {
    clipboard,
    ClipboardItem: item ? FakeItem : undefined,
    Blob: FakeBlob,
    execCopy: (text) => execCopy(text) && copied.push(text) > 0,
    setTimeout: (fun, ms) => {
      timers.set(++nextTimer, {fun, ms})
      return nextTimer
    },
    clearTimeout: (id) => timers.delete(id),
    say: (text) => said.push(text),
    warn: () => {},
  }
  const fire = (ms) => [...timers].filter(([, t]) => t.ms === ms).forEach(([id, t]) => (timers.delete(id), t.fun()))
  return {copier: createExportCopy(env), said, copied, timers, fire}
}

const flush = () => new Promise((resolve) => setImmediate(resolve))
const last = (said) => said[said.length - 1]

test("secure context: the click claims the clipboard, the export fills it", async () => {
  const {copier, said, copied, timers} = setup()

  assert.equal(copier.click(), false)
  assert.equal(last(said), "Copying…")
  copier.arrive({payload: {count: 1}, page: "a,b"}, "a,b")
  await flush()

  assert.deepEqual(copied, [JSON.stringify({count: 1}, null, 2)])
  assert.equal(last(said), "Copied")
  assert.equal(timers.size, 0)
})

test("a server error settles the pending copy at once, with its reason", async () => {
  const {copier, said, copied, timers} = setup()

  copier.click()
  copier.arrive({error: "an EXPLAIN is running", page: "a"}, "a")
  await flush()

  assert.deepEqual(copied, [])
  assert.equal(last(said), "Copy failed: an EXPLAIN is running")
  assert.equal(timers.size, 0)
})

test("a page change settles the pending copy, and a late export is dropped", async () => {
  const {copier, said, copied} = setup()

  copier.click()
  copier.pageChanged()
  copier.arrive({payload: {}, page: "a"}, "a,b")
  await flush()

  assert.deepEqual(copied, [])
  assert.equal(last(said), PAGE_CHANGED)
})

test("an export built for another page is never copied", async () => {
  const {copier, said, copied} = setup()

  copier.click()
  copier.arrive({payload: {}, page: "a"}, "a,b")
  await flush()

  assert.deepEqual(copied, [])
  assert.equal(last(said), PAGE_CHANGED)
})

test("no export within the wait: the copy fails with a way out", async () => {
  const {copier, said, copied, fire} = setup()

  copier.click()
  fire(EXPORT_WAIT_MS)
  await flush()

  assert.deepEqual(copied, [])
  assert.equal(last(said), NO_EXPORT)
})

test("a page change with nothing waiting says nothing", () => {
  const {copier, said} = setup()

  copier.pageChanged()
  assert.deepEqual(said, [])
})

test("insecure context: execCopy on arrival", () => {
  const {copier, said, copied} = setup({item: false, execCopy: () => true})

  copier.click()
  copier.arrive({payload: [1], page: "a"}, "a")

  assert.deepEqual(copied, [JSON.stringify([1], null, 2)])
  assert.equal(last(said), "Copied")
})

test("activation expired: the export is held, the next click copies it", () => {
  let allowed = false
  const {copier, said, copied, timers} = setup({item: false, execCopy: () => allowed})

  copier.click()
  copier.arrive({payload: [1], page: "a"}, "a")
  assert.equal(last(said), "Export ready: click Copy again")

  allowed = true
  assert.equal(copier.click(), true)
  assert.deepEqual(copied, [JSON.stringify([1], null, 2)])
  assert.equal(timers.size, 0)
})

test("a held export is dropped by a new choice or a page change", () => {
  const {copier, said} = setup({item: false})

  copier.arrive({payload: [1], page: "a"}, "a")
  copier.changed()
  assert.equal(copier.click(), false)

  copier.arrive({payload: [1], page: "a"}, "a")
  copier.pageChanged()
  assert.equal(last(said), PAGE_CHANGED)
  assert.equal(copier.click(), false)
})

test("writeText without ClipboardItem copies on arrival", async () => {
  const {copier, said, copied} = setup({item: false, writeText: true})

  copier.click()
  copier.arrive({payload: {}, page: "a"}, "a")
  await flush()

  assert.deepEqual(copied, ["{}"])
  assert.equal(last(said), "Copied")
})

test("a text (the Markdown copy) is copied as is, and a failure does not point at Download", async () => {
  const {copier, copied} = setup({item: false, writeText: true})
  copier.arrive({text: "# page\n| a |", page: "p"}, "p")
  await flush()
  assert.deepEqual(copied, ["# page\n| a |"])

  const said = []
  const quiet = createExportCopy({
    clipboard: {writeText: async () => Promise.reject(new Error("denied"))},
    Blob: FakeBlob,
    fallback: "",
    setTimeout: () => 1,
    clearTimeout: () => {},
    say: (text) => said.push(text),
    warn: () => {},
  })
  quiet.arrive({text: "x", page: "p"}, "p")
  await flush()
  assert.equal(last(said), "Copy failed (Error)")
})

test("messages name the button and the fallback the env gives", async () => {
  const said = []
  const timers = []
  const copier = createExportCopy({
    clipboard: {write: ([entry]) => entry.data["text/plain"].then(() => {}, () => {}), writeText: undefined},
    ClipboardItem: FakeItem,
    Blob: FakeBlob,
    execCopy: () => false,
    fallback: "",
    button: "Copy as Markdown",
    setTimeout: (fun, ms) => (timers.push({fun, ms}), timers.length),
    clearTimeout: () => {},
    say: (text) => said.push(text),
    warn: () => {},
  })

  copier.click()
  timers.find((t) => t.ms === EXPORT_WAIT_MS).fun()
  assert.equal(last(said), "Copy failed: no export arrived")

  copier.arrive({text: "x", page: "a"}, "b")
  assert.equal(last(said), "The page changed: click Copy as Markdown again")
})
