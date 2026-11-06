// The panel's reload breaker (ADR 04): a join LiveView refuses ("stale") sends
// the iframe to its own URL at once, outside LiveView's throttled reload, so a
// panel that can never join would reload without end. Each load is recorded
// per sid; past MAX_LOADS within WINDOW_MS the panel stops connecting.
export const WINDOW_MS = 10_000
export const MAX_LOADS = 3

// The load times kept: the recent ones, plus `now`.
export const record = (times, now) => [...times.filter((t) => now - t < WINDOW_MS), now]

export const tripped = (times) => times.length > MAX_LOADS

// A stored list whose newest load is past the window: its key can go.
export const stale = (times, now) => times.every((t) => now - t >= WINDOW_MS)

// Reads a stored list; anything unexpected counts as none.
export const parse = (raw) => {
  try {
    const times = JSON.parse(raw)
    return Array.isArray(times) ? times.filter((t) => Number.isFinite(t)) : []
  } catch (_error) {
    return []
  }
}
