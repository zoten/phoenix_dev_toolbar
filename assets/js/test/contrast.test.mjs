// Contrast guard for the panel color tokens (ADR 04): every text pair reaches
// WCAG AA (4.5:1) in light and dark mode. Run with `mix test.js`.
import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"

import {luminance, mix, parseHex, ratio} from "../contrast.mjs"

const CSS = readFileSync(new URL("../../css/panel.css", import.meta.url), "utf8")

function tokens(block) {
  const out = {}
  for (const [, name, value] of block.matchAll(/(--pdt-[a-z-]+):\s*(#[0-9a-fA-F]{6})\s*;/g)) out[name] = value
  return out
}

const rootBlock = /:root\s*\{([^}]*)\}/.exec(CSS)?.[1] ?? ""
const darkBlock = /@media\s*\(prefers-color-scheme:\s*dark\)\s*\{\s*:root\s*\{([^}]*)\}/.exec(CSS)?.[1] ?? ""
const LIGHT = tokens(rootBlock)
const DARK = {...LIGHT, ...tokens(darkBlock)}

const HEADER_PAIRS = ["--pdt-header-fg", "--pdt-header-warn", "--pdt-header-error", "--pdt-accent"]
const HEADER_UI = ["--pdt-header-ok"]
const TEXT = ["--pdt-muted", "--pdt-accent-text", "--pdt-ok", "--pdt-warn", "--pdt-error", "--pdt-code"]
const SURFACES = ["--pdt-bg", "--pdt-bg-alt", "--pdt-error-bg"]

function pairs() {
  const list = []
  for (const fg of TEXT) for (const bg of SURFACES) list.push([fg, bg])
  list.push(["#ffffff", "--pdt-error-fill"])
  for (const fg of HEADER_PAIRS) list.push([fg, "--pdt-header"])
  return list
}

// Every checked token declared in a block must be #rrggbb, or the contrast math would skip it.
function formatFailures(block) {
  const checked = new Set([...TEXT, ...SURFACES, ...HEADER_PAIRS, ...HEADER_UI, "--pdt-header", "--pdt-error-fill"])
  const bad = []
  for (const [, name, value] of block.matchAll(/(--pdt-[a-z-]+):\s*([^;]+);/g))
    if (checked.has(name) && !/^#[0-9a-fA-F]{6}$/.test(value.trim()))
      bad.push(`${name}: ${value.trim()} must be #rrggbb`)
  return bad
}

function stripCss(css) {
  return css.replace(/\/\*[\s\S]*?\*\//g, "").replace(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/g, '""')
}

test("the dark block is found and has dark values", () => {
  assert.ok(Object.keys(tokens(darkBlock)).length > 0, "dark block not found or empty")
  assert.ok("--pdt-bg" in tokens(darkBlock), "dark block must declare --pdt-bg")
})

test("checked tokens are declared as #rrggbb in every block", () => {
  assert.deepEqual([...formatFailures(rootBlock), ...formatFailures(darkBlock)], [])
})

test("accent is never used as text color outside .pdt-logo", () => {
  const css = stripCss(CSS)
  const bad = []
  for (const m of css.matchAll(/(?<![-\w])color:\s*var\(--pdt-accent\)/g)) {
    const before = css.slice(0, m.index)
    const selector = before.slice(0, before.lastIndexOf("{")).split(/[{};]/).pop().trim()
    if (selector !== ".pdt-logo") bad.push(`${selector}: use --pdt-accent-text for text`)
  }
  assert.deepEqual(bad, [])
})

test("panel.css braces are balanced", () => {
  let depth = 0
  for (const ch of stripCss(CSS)) {
    if (ch === "{") depth++
    if (ch === "}") depth--
    assert.ok(depth >= 0, "stray closing brace")
  }
  assert.equal(depth, 0, "unclosed brace")
})

test("helpers: black on white is 21, white on white is 1", () => {
  assert.equal(ratio("#000000", "#ffffff"), 21)
  assert.equal(ratio("#ffffff", "#ffffff"), 1)
})

test("helpers: parseHex, luminance and mix", () => {
  assert.deepEqual(parseHex("#fd4f00"), [253, 79, 0])
  assert.equal(luminance("#ffffff"), 1)
  assert.equal(mix("#000000", "#ffffff", 0.5), "#808080")
  assert.equal(mix("#123456", "#ffffff", 1), "#123456")
  assert.throws(() => parseHex("red"))
})

test("helpers: a known pair (#767676 on white is about 4.54)", () => {
  assert.ok(Math.abs(ratio("#767676", "#ffffff") - 4.54) < 0.01)
})

for (const [mode, t] of [["light", LIGHT], ["dark", DARK]]) {
  test(`${mode} mode: every text pair reaches 4.5:1`, () => {
    const failures = []
    for (const [fg, bg] of pairs()) {
      const fgColor = fg.startsWith("#") ? fg : t[fg]
      const bgColor = t[bg]
      if (!fgColor || !bgColor) {
        failures.push(`${fg} on ${bg}: token missing`)
        continue
      }
      const r = ratio(fgColor, bgColor)
      if (r < 4.5) failures.push(`${fg} ${fgColor} on ${bg} ${bgColor}: ${r.toFixed(2)}`)
    }
    assert.deepEqual(failures, [])
  })

  test(`${mode} mode: header UI colors reach 3:1`, () => {
    const failures = []
    for (const fg of HEADER_UI) {
      const r = ratio(t[fg] ?? "#000000", t["--pdt-header"])
      if (!t[fg] || r < 3) failures.push(`${fg} on --pdt-header: ${t[fg]} ${r.toFixed(2)}`)
    }
    assert.deepEqual(failures, [])
  })
}
