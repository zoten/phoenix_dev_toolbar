// Pure shortcut helpers (ADR 04). Run with `mix test.js`.
import {test} from "node:test"
import assert from "node:assert/strict"

import {editable, label, matches, parseShortcut, triggered} from "../shortcut.mjs"

test("parses the canonical form into modifiers and a physical key code", () => {
  assert.deepEqual(parseShortcut("ctrl+shift+d"), {ctrl: true, alt: false, shift: true, meta: false, code: "KeyD", key: "d"})
  assert.equal(parseShortcut("meta+1").code, "Digit1")
  assert.equal(parseShortcut("alt+f5").code, "F5")
  assert.equal(parseShortcut("ctrl+alt+shift+meta+f12").code, "F12")
})

test("anything else does not parse", () => {
  for (const bad of ["d", "ctrl", "ctrl+", "ctrl+dd", "ctrl+f13", "ctrl+f0", "ctrl+ctrl+d", "cmd+d", "ctrl+d+e", "Ctrl+D", "", null, undefined, 5, {}]) {
    assert.equal(parseShortcut(bad), null, String(bad))
  }
})

test("matches checks every modifier exactly", () => {
  const spec = parseShortcut("ctrl+shift+d")
  const press = (extra) => ({code: "KeyD", ctrlKey: true, shiftKey: true, ...extra})

  assert.ok(matches(spec, press({})))
  assert.ok(!matches(spec, press({altKey: true})))
  assert.ok(!matches(spec, press({metaKey: true})))
  assert.ok(!matches(spec, press({shiftKey: false})))
  assert.ok(!matches(spec, press({code: "KeyE"})))
  assert.ok(!matches(null, press({})))
})

test("editable targets are fields and content editable elements", () => {
  assert.ok(editable({tagName: "INPUT"}))
  assert.ok(editable({tagName: "textarea"}))
  assert.ok(editable({tagName: "SELECT"}))
  assert.ok(editable({tagName: "DIV", isContentEditable: true}))
  assert.ok(!editable({tagName: "BUTTON"}))
  assert.ok(!editable(null))
})

test("triggered skips repeats, composition and typing", () => {
  const spec = parseShortcut("alt+f5")
  const press = (extra) => ({code: "F5", altKey: true, target: {tagName: "BODY"}, ...extra})

  assert.ok(triggered(spec, press({})))
  assert.ok(!triggered(spec, press({repeat: true})))
  assert.ok(!triggered(spec, press({isComposing: true})))
  assert.ok(!triggered(spec, press({target: {tagName: "INPUT"}})))
})

test("label reads like a title", () => {
  assert.equal(label("ctrl+shift+d"), "Ctrl+Shift+D")
  assert.equal(label("meta+1"), "Meta+1")
  assert.equal(label("alt+f5"), "Alt+F5")
  assert.equal(label("nope"), "")
})
