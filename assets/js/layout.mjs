// Panel layout (ADR 04): the open panel's size and the page space the toolbar
// reserves. Sizes are along the dock axis (the viewport height for the bottom
// dock), so another dock reuses these with its own axis length.

export const COLLAPSED_SIZE = 34
export const MIN_SIZE = 120
// Strip of page always left visible above the open panel.
export const PAGE_STRIP = 48
const MAX_DEFAULT = 520
const DOCKS = ["bottom"]

export const defaultSize = (viewport) => Math.round(Math.min(viewport * 0.45, MAX_DEFAULT))

export const clampSize = (size, viewport) => {
  const max = Math.max(MIN_SIZE, viewport - PAGE_STRIP)
  const wanted = Number.isFinite(size) ? size : defaultSize(viewport)
  return Math.round(Math.min(Math.max(wanted, MIN_SIZE), max))
}

// The space the toolbar takes in the page flow, so the page can scroll its
// last content above the bar. Hidden leaves only the corner pill: no space.
export const reservedSize = (state, size) => {
  if (state === "open") return size
  if (state === "collapsed") return COLLAPSED_SIZE
  return 0
}

const DEFAULT_LAYOUT = {dock: "bottom", size: null}

export const parseLayout = (raw) => {
  try {
    const {dock, size} = JSON.parse(raw)
    if (!DOCKS.includes(dock)) return {...DEFAULT_LAYOUT}
    return {dock, size: Number.isFinite(size) && size > 0 ? size : null}
  } catch (_error) {
    return {...DEFAULT_LAYOUT}
  }
}

export const serializeLayout = ({dock, size}) => JSON.stringify({dock, size})
