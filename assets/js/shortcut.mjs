// The toolbar's opt-in toggle shortcut (ADR 04): pure helpers shared by the
// loader (host page) and the panel (iframe). The server writes the canonical
// form (`ctrl+shift+d`: modifiers in the order ctrl, alt, shift, meta, then
// one key); the key maps to KeyboardEvent.code, a physical key, so Alt combos
// still match on macOS where event.key changes.
const MODIFIERS = ["ctrl", "alt", "shift", "meta"]
const KEY = /^(?:([a-z])|([0-9])|f([1-9]|1[0-2]))$/
const EDITABLE = ["INPUT", "TEXTAREA", "SELECT"]

// {ctrl, alt, shift, meta, code, key} for a valid canonical string, else null.
export const parseShortcut = (string) => {
  if (typeof string !== "string") return null
  const parts = string.split("+")
  const key = parts.pop()
  const found = KEY.exec(key)
  if (!found || parts.length === 0) return null
  if (parts.some((part) => !MODIFIERS.includes(part)) || new Set(parts).size !== parts.length) return null

  const [, letter, digit, fn] = found
  const code = letter ? `Key${letter.toUpperCase()}` : digit ? `Digit${digit}` : `F${fn}`
  const spec = {code, key}
  MODIFIERS.forEach((name) => (spec[name] = parts.includes(name)))
  return spec
}

// Every modifier must match exactly: Ctrl+Shift+D does not fire on Ctrl+Alt+Shift+D.
export const matches = (spec, event) =>
  Boolean(spec) &&
  event.code === spec.code &&
  Boolean(event.ctrlKey) === spec.ctrl &&
  Boolean(event.altKey) === spec.alt &&
  Boolean(event.shiftKey) === spec.shift &&
  Boolean(event.metaKey) === spec.meta

// Typing in a field must never toggle the toolbar.
export const editable = (target) =>
  Boolean(target) && (EDITABLE.includes(String(target.tagName).toUpperCase()) || target.isContentEditable === true)

// The real target: a listener on window sees an input inside a shadow root
// retargeted to its host element, composedPath()[0] is the input itself.
const realTarget = (event) => (typeof event.composedPath === "function" && event.composedPath()[0]) || event.target

// The keydown guard shared by both listeners: a fresh, matching, non typing
// press that no handler claimed. Windows AltGr reports ctrl+alt: not a combo.
export const triggered = (spec, event) =>
  matches(spec, event) &&
  !event.repeat &&
  !event.isComposing &&
  !event.defaultPrevented &&
  !event.getModifierState?.("AltGraph") &&
  !editable(realTarget(event))

// "Ctrl+Shift+D" for titles.
export const label = (string) => {
  const spec = parseShortcut(string)
  if (!spec) return ""
  const names = {ctrl: "Ctrl", alt: "Alt", shift: "Shift", meta: "Meta"}
  return [...MODIFIERS.filter((name) => spec[name]).map((name) => names[name]), spec.key.toUpperCase()].join("+")
}
