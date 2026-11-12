// Pure WCAG contrast helpers, used only by the contrast test (ADR 04).
// Never imported by loader.js or panel.js, so it never reaches a bundle.

/** Parses `#rrggbb` into `[r, g, b]` (0..255). */
export function parseHex(hex) {
  const m = /^#([0-9a-f]{6})$/i.exec(hex.trim())
  if (!m) throw new Error(`not a #rrggbb color: ${hex}`)
  const n = parseInt(m[1], 16)
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
}

/** WCAG relative luminance of a `#rrggbb` color. */
export function luminance(hex) {
  const [r, g, b] = parseHex(hex).map((c) => {
    const s = c / 255
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4
  })
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

/** WCAG contrast ratio between two `#rrggbb` colors (1..21). */
export function ratio(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (hi + 0.05) / (lo + 0.05)
}

/** Blends `a` over `b`: `weight` is the share of `a` (like `color-mix` or opacity). */
export function mix(a, b, weight) {
  const [pa, pb] = [parseHex(a), parseHex(b)]
  const out = pa.map((c, i) => Math.round(c * weight + pb[i] * (1 - weight)))
  return "#" + out.map((c) => c.toString(16).padStart(2, "0")).join("")
}
