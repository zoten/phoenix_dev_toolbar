// Panel layout (ADR 04): where the toolbar docks, the open panel's size and the
// page space the toolbar reserves. Sizes are along the dock's axis: the
// viewport height for top and bottom, its width for left and right.

export const DOCKS = ["bottom", "top", "left", "right"]
export const DEFAULT_DOCK = "bottom"
export const COLLAPSED_SIZE = 34
// Strip of page always left visible beside the open panel.
export const PAGE_STRIP = 48

const BOUNDS = {
  edge: {min: 120, ratio: 0.45, max: 520},
  side: {min: 280, ratio: 0.4, max: 480},
}

export const sideDock = (dock) => dock === "left" || dock === "right"

const bounds = (dock) => (sideDock(dock) ? BOUNDS.side : BOUNDS.edge)

export const minSize = (dock) => bounds(dock).min

export const maxSize = (viewport, dock) => Math.max(minSize(dock), viewport - PAGE_STRIP)

export const defaultSize = (viewport, dock) => {
  const {ratio, max} = bounds(dock)
  return Math.round(Math.min(viewport * ratio, max))
}

export const clampSize = (size, viewport, dock) => {
  const wanted = Number.isFinite(size) ? size : defaultSize(viewport, dock)
  return Math.round(Math.min(Math.max(wanted, minSize(dock)), maxSize(viewport, dock)))
}

// The size a drag asks for, from the pointer and the viewport.
export const sizeFromPointer = (dock, x, y, width, height) =>
  ({bottom: height - y, top: y, left: x, right: width - x})[dock]

// The space the toolbar takes in the page, so the page can show its edge
// beside the bar. Hidden leaves only the corner pill, and an opted out page
// (`reserve` false) lets the bar overlap it: no space.
export const reservedSize = (state, size, reserve = true) => {
  if (!reserve) return 0
  if (state === "open") return size
  if (state === "collapsed") return COLLAPSED_SIZE
  return 0
}

const validSize = (size) => Number.isFinite(size) && size > 0

const pickSizes = (sizes) =>
  Object.fromEntries(DOCKS.filter((dock) => validSize(sizes[dock])).map((dock) => [dock, sizes[dock]]))

const defaultLayout = () => ({dock: DEFAULT_DOCK, sizes: {}, reserve: null})

// The user's page space choice: a boolean overrides the server's default, null
// follows it.
const pickReserve = (reserve) => (typeof reserve === "boolean" ? reserve : null)

// Reads `{dock, sizes, reserve}`, and the older `{dock: "bottom", size}` shape.
// Anything unknown falls back to the default.
export const parseLayout = (raw) => {
  try {
    const parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== "object") return defaultLayout()
    const dock = DOCKS.includes(parsed.dock) ? parsed.dock : DEFAULT_DOCK
    const reserve = pickReserve(parsed.reserve)
    if (parsed.sizes && typeof parsed.sizes === "object") return {dock, sizes: pickSizes(parsed.sizes), reserve}
    return {dock, sizes: validSize(parsed.size) ? {[dock]: parsed.size} : {}, reserve}
  } catch (_error) {
    return defaultLayout()
  }
}

export const serializeLayout = ({dock, sizes, reserve}) =>
  JSON.stringify(typeof reserve === "boolean" ? {dock, sizes, reserve} : {dock, sizes})

// Whether the page makes room: the user's choice, else the server's default
// (the loader tag's data-pdt-reserve, only ever written as "false").
export const reserving = (layout, attribute) =>
  typeof layout.reserve === "boolean" ? layout.reserve : attribute !== "false"
