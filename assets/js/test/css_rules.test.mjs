// Rules for panel.css (ADR 04). Run with `mix test.js`.
import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"

const CSS = readFileSync(new URL("../../css/panel.css", import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "")

// Removes `min(...)`/`clamp(...)` groups (nested parentheses included): a px cap there is intended.
function stripCaps(value) {
  let out = value
  for (;;) {
    const next = out.replace(/\b(?:min|clamp)\([^()]*\)/g, "")
    if (next === out) return out
    out = next
  }
}

test("font sizes are in rem, a px size only inside min() or clamp()", () => {
  const offenders = []
  for (const [, prop, value] of CSS.matchAll(/(?:^|[;{\s])(font(?:-size)?)\s*:\s*([^;}]+)/g)) {
    if (/\d(?:\.\d+)?px\b/.test(stripCaps(value).replace(/\/\s*[\d.]+px/, ""))) offenders.push(`${prop}: ${value.trim()}`)
  }
  assert.deepEqual(offenders, [])
})
