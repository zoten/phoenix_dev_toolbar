// The Ecto tab's Copy (ADR 08), without the DOM: the PdtExport hook in
// panel.js passes the clipboard, timers and the result line in `env`.
//
// The export arrives after a round trip (and EXPLAINs), too late for the
// click's user activation. Where ClipboardItem exists (secure contexts: https
// or localhost), the write starts in the click with a promised blob, resolved
// when the export arrives. Elsewhere (plain http on a LAN IP) execCopy runs on
// arrival, and when the activation has expired the JSON is held and the next
// Copy click copies it. An export names the page it was built from: one that
// no longer matches the form's is dropped, never copied. A server error (a
// busy tab, a crashed export) settles the pending copy at once.

export const EXPORT_WAIT_MS = 60000
export const HELD_MS = 60000
export const PAGE_CHANGED = "The page changed: click Copy again"
export const NO_EXPORT = "Copy failed: no export arrived, use Download"

export const createExportCopy = (env) => {
  let pending = null
  let held = null

  const drop = () => {
    if (!held) return false
    env.clearTimeout(held.timer)
    held = null
    return true
  }

  // Abandons the pending copy, showing `message` now: its rejected write stays quiet.
  const abandon = (message) => {
    if (!pending) return false
    const copy = pending
    pending = null
    env.clearTimeout(copy.timer)
    copy.abandoned = true
    copy.reject(new Error("no export"))
    if (message) env.say(message)
    return true
  }

  const fulfil = (json) => {
    if (!pending) return false
    const copy = pending
    pending = null
    env.clearTimeout(copy.timer)
    copy.resolve(new env.Blob([json], {type: "text/plain"}))
    return true
  }

  // `env.fallback` names what to use when the clipboard refuses (Download for
  // the Ecto export, nothing for the Markdown copy).
  const fallback = env.fallback === undefined ? ": use Download" : env.fallback

  const failed = (error) => {
    env.warn(error)
    const why = (error && (error.name || error.message)) || "refused"
    env.say("Copy failed (" + why + ")" + fallback)
  }

  // In the click: claims the clipboard now, the text comes later.
  const startCopy = () => {
    const clipboard = env.clipboard
    if (!clipboard || !clipboard.write || !env.ClipboardItem) return
    abandon(null)
    let resolve, reject
    const text = new Promise((ok, fail) => {
      resolve = ok
      reject = fail
    })
    const copy = {resolve, reject, abandoned: false}
    copy.timer = env.setTimeout(() => abandon(NO_EXPORT), EXPORT_WAIT_MS)
    pending = copy
    env.say("Copying…")
    clipboard.write([new env.ClipboardItem({"text/plain": text})]).then(
      () => env.say("Copied"),
      (error) => copy.abandoned || failed(error),
    )
  }

  const hold = (json) => {
    drop()
    held = {json, timer: env.setTimeout(drop, HELD_MS)}
    env.say("Export ready: click Copy again")
  }

  const copyNow = (json) => {
    if (fulfil(json)) return
    const clipboard = env.clipboard
    if (clipboard && clipboard.writeText) {
      clipboard.writeText(json).then(() => env.say("Copied"), failed)
    } else if (env.execCopy(json)) {
      env.say("Copied")
    } else {
      hold(json)
    }
  }

  return {
    // A Copy click. True when it copied the held export: the caller then stops
    // the submit, no new export is needed.
    click() {
      if (!held) {
        startCopy()
        return false
      }
      const json = held.json
      drop()
      env.say(env.execCopy(json) ? "Copied" : "Copy failed" + fallback)
      return true
    },
    // A `pdt:export` push, with the page the form shows now.
    // A `text` (the Markdown copy) is copied as is, a `payload` as JSON.
    arrive({payload, text, page, error}, formPage) {
      if (page !== formPage) {
        drop()
        if (!abandon(PAGE_CHANGED)) env.say(PAGE_CHANGED)
      } else if (error) {
        drop()
        const message = "Copy failed: " + error
        if (!abandon(message)) env.say(message)
      } else {
        copyNow(typeof text === "string" ? text : JSON.stringify(payload, null, 2))
      }
    },
    // The form now shows another page: what was waiting no longer matches it.
    pageChanged() {
      const dropped = drop()
      if (!abandon(PAGE_CHANGED) && dropped) env.say(PAGE_CHANGED)
    },
    // A new choice in the form: the held export no longer matches it.
    changed() {
      drop()
    },
    destroy() {
      drop()
      abandon(null)
    },
  }
}
