// Client event log helpers for the loader (ADR 07). Pure functions, unit
// tested with `mix test.js`; bundled into loader.js by esbuild.
//
// The loader only reads LiveView's own window events. Their `detail` comes
// from the host page, so only a few scalar fields are copied, never objects,
// and only through own data properties (a host getter never runs).

export const EVENTS = ["phx:page-loading-start", "phx:page-loading-stop", "phx:navigate"]
export const FIELDS = ["kind", "to", "href", "patch", "pop"]
export const MAX_STRING = 256
export const BUFFER = 50
export const PER_SECOND = 20

const scalar = (value) => {
  if (typeof value === "string") {
    return value.length > MAX_STRING ? value.slice(0, MAX_STRING) + "…" : value
  }
  if (typeof value === "boolean" || (typeof value === "number" && Number.isFinite(value))) return value
  return undefined
}

const ownValue = (object, field) => {
  const descriptor = Object.getOwnPropertyDescriptor(object, field)
  return descriptor && "value" in descriptor ? descriptor.value : undefined
}

export const sanitize = (type, detail, at) => {
  const event = {type, at}
  if (!detail || typeof detail !== "object") return event

  for (const field of FIELDS) {
    const value = scalar(ownValue(detail, field))
    if (value !== undefined) event[field] = value
  }
  return event
}

// At most `perSecond` events per wall clock second; the rest are counted.
export const createLimiter = (perSecond) => {
  let second = null
  let count = 0
  let dropped = 0

  return {
    allow(nowMs) {
      const current = Math.floor(nowMs / 1000)
      if (current !== second) {
        second = current
        count = 0
      }
      if (count < perSecond) {
        count += 1
        return true
      }
      dropped += 1
      return false
    },
    dropped: () => dropped,
  }
}

// Holds up to `limit` items until `ready()`, then sends them and every later
// item directly; items over the limit are counted.
export const createQueue = (limit, send) => {
  let buffer = []
  let isReady = false
  let dropped = 0

  return {
    push(item) {
      if (isReady) send(item)
      else if (buffer.length < limit) buffer.push(item)
      else dropped += 1
    },
    ready() {
      isReady = true
      const pending = buffer
      buffer = []
      pending.forEach(send)
    },
    dropped: () => dropped,
  }
}
