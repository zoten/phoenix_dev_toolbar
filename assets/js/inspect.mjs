// The element inspector's pure helpers (ADR 16), shared by the loader (host
// page). `resolve` turns a picked element into the payload the panel sends to
// the server; it reads LiveView's HEEx debug annotations (comment nodes) and
// `data-phx-*` attributes and never writes to the page. Host DOM text is
// untrusted input: the walk is capped and every string truncated here, and the
// server bounds it again.
export const MAX_NODES = 500
export const MIN_NODES = 50
export const LIMIT_NODES = 10_000
export const MAX_FRAMES = 20
export const MAX_STRING_BYTES = 512
export const MAX_INTEGER = 10_000_000

const COMMENT = 8
const ELEMENT = 1
const BINDINGS = ["phx-click", "phx-submit", "phx-change"]
// `<Mod.fun> lib/file.ex:12 (app)`: the `(app)` suffix may be absent. Slots
// (`<:name> ...`) start with a colon and do not match.
const OPEN = /^\s*<([^\s<>:/][^\s<>]*)>\s+(\S+):(\d+)(?:\s+\([^)]*\))?\s*$/
const CLOSE = /^\s*<\/([^\s<>]+)>\s*$/
const CALLER = /^\s*@caller\s+(\S+):(\d+)(?:\s+\([^)]*\))?\s*$/

const encoder = new TextEncoder()

// At most MAX_STRING_BYTES bytes of UTF-8, cut on a character boundary.
export const truncate = (value) => {
  let string = String(value)
  if (string.length > MAX_STRING_BYTES) string = string.slice(0, MAX_STRING_BYTES)
  while (encoder.encode(string).length > MAX_STRING_BYTES) string = string.slice(0, -1)
  // A cut between the halves of a surrogate pair leaves a lone high surrogate.
  return string.replace(/[\uD800-\uDBFF]$/, "")
}

// An integer in 0..MAX_INTEGER from digits, else null.
export const integer = (value) => {
  if (typeof value !== "string" && typeof value !== "number") return null
  const text = String(value).trim()
  if (!/^\d{1,8}$/.test(text)) return null
  const number = Number(text)
  return number <= MAX_INTEGER ? number : null
}

const attr = (element, name) => {
  const value = element.getAttribute(name)
  return value === null || value === undefined ? null : value
}

const comment = (node) => node && node.nodeType === COMMENT && typeof node.data === "string"

// The previous sibling that is not whitespace-only text.
const TEXT = 3
const previous = (node) => {
  let sibling = node.previousSibling
  while (sibling && sibling.nodeType === TEXT && !/\S/.test(sibling.data || "")) sibling = sibling.previousSibling
  return sibling
}

const frame = (open, node) => {
  const [, name, file, line] = open
  const found = {name: truncate(name), file: truncate(file), line: integer(line)}
  const before = previous(node)
  const caller = comment(before) ? CALLER.exec(before.data) : null
  return {frame: found, caller: caller ? {file: truncate(caller[1]), line: integer(caller[2])} : null}
}

// Open function component frames around `element`, innermost first, and the
// @caller of the innermost one. Per level: the previous siblings of the
// element or of the ancestor, nearest first; a close annotation seen first
// cancels the open annotation of the same name before it. The walk stops at the
// LiveView root (its children are scanned, its own siblings are not), or at
// the body of a dead render.
const walk = (element, root, maxNodes) => {
  const frames = []
  let caller = null
  let visited = 0
  let node = element
  const budget = () => ++visited <= maxNodes

  while (node && node !== root && node.nodeType === ELEMENT && node.tagName !== "body" && node.tagName !== "BODY") {
    const closed = new Map()
    for (let sibling = node.previousSibling; sibling; sibling = sibling.previousSibling) {
      if (!budget()) return {frames, caller, truncated: true}
      if (!comment(sibling)) continue

      const close = CLOSE.exec(sibling.data)
      if (close) {
        closed.set(close[1], (closed.get(close[1]) || 0) + 1)
        continue
      }
      const open = OPEN.exec(sibling.data)
      if (!open) continue
      if (closed.get(open[1]) > 0) {
        closed.set(open[1], closed.get(open[1]) - 1)
        continue
      }
      if (frames.length >= MAX_FRAMES) return {frames, caller, truncated: false}
      const found = frame(open, sibling)
      if (frames.length === 0) caller = found.caller
      frames.push(found.frame)
    }
    if (!budget()) return {frames, caller, truncated: true}
    node = node.parentNode
  }
  return {frames, caller, truncated: false}
}

// The closest element, self or ancestor, inside the root, with a phx-click,
// phx-submit or phx-change binding.
const binding = (element, root) => {
  for (let node = element; node && node.nodeType === ELEMENT; node = node.parentNode) {
    const event = BINDINGS.find((name) => attr(node, name) !== null)
    if (event) {
      const target = attr(node, "phx-target")
      return {event, name: truncate(attr(node, event)), target: target === null ? null : truncate(target)}
    }
    if (node === root) break
  }
  return null
}

// A walk budget from a data attribute: an integer in MIN_NODES..LIMIT_NODES,
// else the default.
export const nodeBudget = (value) => {
  const text = typeof value === "string" ? value.trim() : ""
  const number = /^\d{1,5}$/.test(text) ? Number(text) : NaN
  return number >= MIN_NODES && number <= LIMIT_NODES ? number : MAX_NODES
}

// The payload of the contract (ADR 16) for a picked element. `maxNodes` is the
// walk budget; `truncated` is true when it ran out before the root.
export const resolve = (element, {maxNodes = MAX_NODES} = {}) => {
  const root = element.closest("[data-phx-session]")
  const found = element.closest("[data-phx-component]")
  // Cids are per LiveView: a component outside this root belongs to a parent.
  const component = found && (!root || root.contains(found)) ? found : null
  const rootId = root ? attr(root, "id") : null
  const {frames, caller, truncated} = walk(element, root, maxNodes)

  return {
    root: rootId === null ? null : truncate(rootId),
    cid: component ? integer(attr(component, "data-phx-component")) : null,
    tag: truncate(String(element.tagName).toLowerCase()),
    tag_line: integer(attr(element, "data-phx-loc")),
    binding: binding(element, root),
    frames,
    caller,
    truncated,
  }
}

// The viewport rect to draw (position: fixed) around an element.
export const outlineBox = (element) => {
  const {left, top, width, height} = element.getBoundingClientRect()
  return {left, top, width, height}
}
