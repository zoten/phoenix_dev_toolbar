// The collapsed bar's badge overflow (ADR 04): the summary is one row tall and
// wraps, so badges that do not fit land on rows out of sight. Given each
// badge's offsetTop, counts those below the first row.
export const countWrapped = (tops) => {
  if (tops.length === 0) return 0
  const firstRow = Math.min(...tops)
  return tops.filter((top) => top > firstRow).length
}
