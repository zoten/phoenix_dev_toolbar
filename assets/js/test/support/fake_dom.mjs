// A minimal fake DOM for the loader and panel wiring tests (ADR 06): just the
// window, document, element, storage and event surface that loader.js and
// panel.js touch, so the tests stay on Node built-ins. Selectors are compound
// only (`tag#id.class[attr][attr='value']`), no combinators.

export class FakeEvent {
  constructor(type, init = {}) {
    Object.assign(this, init)
    this.type = type
    this.defaultPrevented = false
    this.stopped = false
  }

  preventDefault() {
    this.defaultPrevented = true
  }

  stopPropagation() {
    this.stopped = true
  }
}

class Target {
  constructor() {
    this.listeners = new Map()
  }

  addEventListener(type, fun, options = {}) {
    const list = this.listeners.get(type) || []
    const object = typeof options === "object" && options !== null
    const capture = object ? Boolean(options.capture) : options === true
    list.push({fun, capture, once: object && options.once})
    this.listeners.set(type, list)
  }

  removeEventListener(type, fun, options = {}) {
    const object = typeof options === "object" && options !== null
    const capture = object ? Boolean(options.capture) : options === true
    const list = this.listeners.get(type) || []
    this.listeners.set(type, list.filter((listener) => listener.fun !== fun || listener.capture !== capture))
  }

  // `phase` limits the call to the capture or the bubble listeners; without
  // one every listener runs.
  fire(event, phase) {
    for (const listener of [...(this.listeners.get(event.type) || [])]) {
      if (phase && listener.capture !== (phase === "capture")) continue
      if (listener.once) this.removeEventListener(event.type, listener.fun, {capture: listener.capture})
      listener.fun.call(this, event)
    }
  }

  // Capture listeners run from the outermost node down to the target, then
  // bubble listeners from the target up to the document (never out of a
  // shadow root). stopPropagation ends the walk.
  dispatchEvent(event) {
    if (!event.target) event.target = this
    const path = []
    for (let node = this; node; node = node.parentNode) path.push(node)
    // Events on the document continue to the window, as in a browser.
    if (path[path.length - 1] === this.ownerDocument && globalThis.window) path.push(globalThis.window)
    for (const node of [...path].reverse()) {
      if (event.stopped) break
      node.fire(event, "capture")
    }
    for (const node of path) {
      if (event.stopped) break
      node.fire(event, "bubble")
    }
    return !event.defaultPrevented
  }
}

const parseSelector = (selector) => {
  const parts = {tag: null, ids: [], classes: [], attrs: []}
  const tag = selector.match(/^[a-z][a-z0-9-]*/)
  let rest = selector
  if (tag) {
    parts.tag = tag[0]
    rest = rest.slice(tag[0].length)
  }
  const token = /^(?:#([\w-]+)|\.([\w-]+)|\[([\w-]+)(?:=(['"])(.*?)\4)?\])/
  while (rest.length > 0) {
    const match = rest.match(token)
    if (!match) throw new Error(`fake DOM: unsupported selector ${selector}`)
    if (match[1]) parts.ids.push(match[1])
    if (match[2]) parts.classes.push(match[2])
    if (match[3]) parts.attrs.push({name: match[3], value: match[5]})
    rest = rest.slice(match[0].length)
  }
  return parts
}

const camel = (name) => name.replace(/-([a-z])/g, (_all, letter) => letter.toUpperCase())

class ClassList {
  constructor(el) {
    this.el = el
  }

  get names() {
    return (this.el.getAttribute("class") || "").split(/\s+/).filter(Boolean)
  }

  write(names) {
    this.el.setAttribute("class", names.join(" "))
  }

  contains(name) {
    return this.names.includes(name)
  }

  add(name) {
    if (!this.contains(name)) this.write([...this.names, name])
  }

  remove(name) {
    this.write(this.names.filter((other) => other !== name))
  }

  toggle(name, force) {
    const on = force === undefined ? !this.contains(name) : Boolean(force)
    if (on) this.add(name)
    else this.remove(name)
    return on
  }
}

class Style {
  constructor() {
    this.props = new Map()
  }

  setProperty(name, value, priority = "") {
    if (value === "" || value == null) this.props.delete(name)
    else this.props.set(name, {value: String(value), priority})
  }

  getPropertyValue(name) {
    return this.props.has(name) ? this.props.get(name).value : ""
  }

  getPropertyPriority(name) {
    return this.props.has(name) ? this.props.get(name).priority : ""
  }

  set cssText(text) {
    this.props.clear()
    text
      .split(";")
      .map((decl) => decl.split(":").map((part) => part.trim()))
      .filter(([name, value]) => name && value)
      .forEach(([name, value]) => this.setProperty(name, value))
  }

  get height() {
    return this.getPropertyValue("height")
  }

  set height(value) {
    this.setProperty("height", value)
  }
}

class Node extends Target {
  constructor(document) {
    super()
    this.ownerDocument = document
    this.parentNode = null
    this.childNodes = []
  }

  // Elements only, like the DOM; `childNodes` also holds text and comments.
  get children() {
    return this.childNodes.filter((node) => node.nodeType === 1)
  }

  get firstChild() {
    return this.childNodes[0] || null
  }

  get nodeType() {
    return 9
  }

  get parentElement() {
    return this.parentNode instanceof FakeElement ? this.parentNode : null
  }

  get previousSibling() {
    const siblings = this.parentNode ? this.parentNode.childNodes : []
    return siblings[siblings.indexOf(this) - 1] || null
  }

  get lastChild() {
    return this.childNodes[this.childNodes.length - 1] || null
  }

  insert(index, nodes) {
    nodes.forEach((node) => node.remove())
    nodes.forEach((node) => {
      node.parentNode = this
    })
    this.childNodes.splice(index, 0, ...nodes)
  }

  append(...nodes) {
    this.insert(this.childNodes.length, nodes)
  }

  appendChild(node) {
    this.append(node)
    return node
  }

  prepend(...nodes) {
    this.insert(0, nodes)
  }

  *descendants() {
    for (const child of this.childNodes) {
      yield child
      yield* child.descendants()
    }
  }

  querySelectorAll(selector) {
    return [...this.descendants()].filter((el) => el.matches(selector))
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null
  }
}

// A comment node (HEEx debug annotations): nodeType 8, `data` is the text.
export class FakeComment extends Node {
  constructor(document, data) {
    super(document)
    this.data = data
  }

  get nodeType() {
    return 8
  }

  matches() {
    return false
  }

  remove() {
    if (!this.parentNode) return
    const siblings = this.parentNode.childNodes
    siblings.splice(siblings.indexOf(this), 1)
    this.parentNode = null
  }
}

// A text node: nodeType 3, `data` is the text.
export class FakeText extends FakeComment {
  get nodeType() {
    return 3
  }
}

export class FakeElement extends Node {
  constructor(document, tagName) {
    super(document)
    this.tagName = tagName.toLowerCase()
    this.attributes = new Map()
    this.classList = new ClassList(this)
    this.style = new Style()
    this.shadowRoot = null
    this.hidden = false
    this.textContent = ""
    this.popoverOpen = false
    this.popoverInvoker = null
  }

  get nodeType() {
    return 1
  }

  get id() {
    return this.getAttribute("id") || ""
  }

  set id(value) {
    this.setAttribute("id", value)
  }

  get className() {
    return this.getAttribute("class") || ""
  }

  set className(value) {
    this.setAttribute("class", value)
  }

  get dataset() {
    return Object.fromEntries(
      [...this.attributes]
        .filter(([name]) => name.startsWith("data-"))
        .map(([name, value]) => [camel(name.slice(5)), value]),
    )
  }

  get isConnected() {
    let node = this
    while (node.parentNode) node = node.parentNode
    return node === this.ownerDocument
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value))
  }

  getAttribute(name) {
    return this.attributes.has(name) ? this.attributes.get(name) : null
  }

  hasAttribute(name) {
    return this.attributes.has(name)
  }

  removeAttribute(name) {
    this.attributes.delete(name)
  }

  remove() {
    if (!this.parentNode) return
    const siblings = this.parentNode.childNodes
    siblings.splice(siblings.indexOf(this), 1)
    this.parentNode = null
  }

  after(node) {
    const parent = this.parentNode
    parent.insert(parent.childNodes.indexOf(this) + 1, [node])
  }

  matches(selector) {
    if (selector === ":popover-open") return this.popoverOpen
    const {tag, ids, classes, attrs} = parseSelector(selector)
    return (
      (!tag || tag === this.tagName) &&
      ids.every((id) => id === this.id) &&
      classes.every((name) => this.classList.contains(name)) &&
      attrs.every(({name, value}) => this.hasAttribute(name) && (value === undefined || this.getAttribute(name) === value))
    )
  }

  closest(selector) {
    for (let el = this; el instanceof FakeElement; el = el.parentNode) {
      if (el.matches(selector)) return el
    }
    return null
  }

  contains(node) {
    for (let el = node; el; el = el.parentNode) if (el === this) return true
    return false
  }

  attachShadow() {
    this.shadowRoot = new Node(this.ownerDocument)
    this.shadowRoot.host = this
    this.shadowRoot.activeElement = null
    return this.shadowRoot
  }

  // Inside a shadow root the root tracks the focused element and the document
  // sees the shadow host, as in a browser.
  focus() {
    let top = this
    while (top.parentNode) top = top.parentNode
    const before = this.ownerDocument.activeElement
    if (!top.host && before && before.shadowRoot) before.shadowRoot.activeElement = null
    if (top.host) top.activeElement = this
    this.ownerDocument.activeElement = top.host || this
  }

  // The Popover API, as far as the panel uses it: popover="auto" elements open
  // in a document-wide list, toggle events fire synchronously with
  // oldState/newState (they do not bubble in a browser: panel.js listens in the
  // capture phase), light dismiss closes on an outside click and on Escape, and
  // closing returns focus to the invoker (`document.popoverReturnsFocus = false`
  // models a browser that does not).
  showPopover(invoker = null) {
    if (!this.hasAttribute("popover")) throw new Error("NotSupportedError")
    if (this.popoverOpen) throw new Error("InvalidStateError")
    this.popoverOpen = true
    this.popoverInvoker = invoker
    this.fireToggle("closed", "open")
  }

  hidePopover() {
    if (!this.hasAttribute("popover")) throw new Error("NotSupportedError")
    if (!this.popoverOpen) return
    const hadFocus = this.contains(this.ownerDocument.activeElement)
    this.popoverOpen = false
    if (hadFocus && this.ownerDocument.popoverReturnsFocus && this.popoverInvoker) this.popoverInvoker.focus()
    else if (hadFocus) this.ownerDocument.activeElement = this.ownerDocument.body
    this.fireToggle("open", "closed")
  }

  togglePopover() {
    if (this.popoverOpen) this.hidePopover()
    else this.showPopover()
    return this.popoverOpen
  }

  fireToggle(oldState, newState) {
    this.fire(Object.assign(new FakeEvent("toggle", {oldState, newState}), {target: this}))
    for (let node = this.parentNode; node; node = node.parentNode) {
      node.fire(Object.assign(new FakeEvent("toggle", {oldState, newState}), {target: this}))
    }
  }

  dispatchEvent(event) {
    const result = super.dispatchEvent(event)
    if (event.type === "keydown" && event.key === "Escape" && !event.defaultPrevented) {
      const open = this.ownerDocument.openPopovers()
      if (open.length > 0) open[open.length - 1].hidePopover()
    }
    return result
  }

  click() {
    const doc = this.ownerDocument
    const invoker = this.closest("[popovertarget]")
    doc.openPopovers().forEach((popover) => {
      const own = invoker && invoker.getAttribute("popovertarget") === popover.id
      if (!popover.contains(this) && !own) popover.hidePopover()
    })
    const result = this.dispatchEvent(new FakeEvent("click", {button: 0}))
    const target = invoker && !this.hasAttribute("disabled") && doc.getElementById(invoker.getAttribute("popovertarget"))
    if (target && result && target.hasAttribute("popover")) {
      if (target.popoverOpen) target.hidePopover()
      else target.showPopover(invoker)
    }
    return result
  }

  setPointerCapture() {}

  select() {}

  // Tests set `rect` to place an element.
  getBoundingClientRect() {
    return this.rect || {left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0}
  }
}

export class FakeStorage {
  constructor(entries = {}) {
    this.map = new Map(Object.entries(entries))
  }

  get length() {
    return this.map.size
  }

  key(index) {
    return [...this.map.keys()][index] ?? null
  }

  getItem(key) {
    return this.map.has(key) ? this.map.get(key) : null
  }

  setItem(key, value) {
    this.map.set(key, String(value))
  }

  removeItem(key) {
    this.map.delete(key)
  }
}

// Storage the browser refuses (disabled cookies, some private modes): every call throws.
export class BlockedStorage {
  get length() {
    throw new Error("SecurityError")
  }

  key() {
    throw new Error("SecurityError")
  }

  getItem() {
    throw new Error("SecurityError")
  }

  setItem() {
    throw new Error("SecurityError")
  }

  removeItem() {
    throw new Error("SecurityError")
  }
}

// A window seen from elsewhere: it records what is posted to it.
export class FakeWindow extends Target {
  constructor({origin}) {
    super()
    this.location = {origin}
    this.posted = []
  }

  postMessage(data, targetOrigin) {
    this.posted.push({data, targetOrigin})
  }

  // The runtime's timers, looked up per call so a test's mocked timers apply.
  setTimeout(fun, ms) {
    return globalThis.setTimeout(fun, ms)
  }

  clearTimeout(timer) {
    globalThis.clearTimeout(timer)
  }
}

class FakeDocument extends Node {
  constructor() {
    super(null)
    this.ownerDocument = this
    this.currentScript = null
    this.visibilityState = "visible"
    this.activeElement = null
    this.popoverReturnsFocus = true
    this.documentElement = this.createElement("html")
    this.append(this.documentElement)
  }

  get body() {
    return this.documentElement.children.find((el) => el.tagName === "body") || null
  }

  createElement(tagName) {
    const el = new FakeElement(this, tagName)
    if (el.tagName === "iframe") el.contentWindow = new FakeWindow({origin: null})
    return el
  }

  createTextNode(data) {
    return new FakeText(this, data)
  }

  createComment(data) {
    return new FakeComment(this, data)
  }

  openPopovers() {
    return [...this.descendants()].filter((el) => el.popoverOpen)
  }

  getElementById(id) {
    return [...this.descendants()].find((el) => el.id === id) || null
  }
}

// Builds a page and installs it as the globals the scripts read. `restore`
// puts the previous globals back.
export const installDom = ({origin = "http://localhost:4000", search = "", body = true, framed = false} = {}) => {
  const document = new FakeDocument()
  if (body) document.documentElement.append(document.createElement("body"))

  const window = new FakeWindow({origin})
  window.location = {origin, search, reloads: 0, reload: () => window.location.reloads++}
  window.top = window
  window.parent = window
  if (framed) {
    window.parent = new FakeWindow({origin})
    window.top = window.parent
  }
  window.localStorage = new FakeStorage()
  window.sessionStorage = new FakeStorage()
  window.innerWidth = 1280
  window.innerHeight = 800
  window.getComputedStyle = () => ({getPropertyValue: () => ""})

  const frames = []
  const globals = {
    window,
    document,
    requestAnimationFrame: (fun) => frames.push(fun),
    cancelAnimationFrame: () => {},
  }
  const previous = Object.fromEntries(Object.keys(globals).map((key) => [key, globalThis[key]]))
  Object.assign(globalThis, globals)

  // A script tag, as the page would carry it: the module reads it as currentScript.
  const script = (attributes, nonce) => {
    const el = document.createElement("script")
    Object.entries(attributes).forEach(([name, value]) => el.setAttribute(name, value))
    if (nonce) el.nonce = nonce
    document.documentElement.append(el)
    document.currentScript = el
    return el
  }

  // Builds an element tree: [tag, attributes, ...children], children may be text.
  // `["#comment", " text "]` is a comment node.
  const build = ([tag, attributes = {}, ...children]) => {
    if (tag === "#comment") return document.createComment(attributes)
    const el = document.createElement(tag)
    Object.entries(attributes).forEach(([name, value]) => {
      if (name === "hidden") el.hidden = value
      else if (name === "popover" && value === true) el.setAttribute(name, "auto")
      else el.setAttribute(name, value === true ? "" : value)
    })
    children.forEach((child) => {
      if (typeof child === "string") {
        el.textContent += child
        el.append(document.createTextNode(child))
      }
      else el.append(build(child))
    })
    return el
  }

  return {
    window,
    document,
    script,
    build,
    // Runs the pending animation frames, as the browser does on its next paint.
    pendingFrames: () => frames.length,
    flushFrames: () => frames.splice(0).forEach((fun) => fun(0)),
    restore: () => Object.assign(globalThis, previous),
  }
}

// A fresh module instance per call: the scripts run their setup at import.
let loads = 0
export const freshImport = (url) => import(`${url}?load=${++loads}`)

// A message event as the browser delivers it to `window`.
export const message = (data, {origin, source}) => new FakeEvent("message", {data, origin, source})

// Lets the pending promise callbacks (a clipboard write, say) run.
export const flush = () => new Promise((resolve) => setImmediate(resolve))

// Replaces Node's `navigator` global for the test (the panel's hooks read
// navigator.clipboard); the test context puts the original back.
export const stubNavigator = (t, navigator) => {
  const saved = Object.getOwnPropertyDescriptor(globalThis, "navigator")
  Object.defineProperty(globalThis, "navigator", {configurable: true, value: navigator})
  t.after(() => (saved ? Object.defineProperty(globalThis, "navigator", saved) : delete globalThis.navigator))
}
