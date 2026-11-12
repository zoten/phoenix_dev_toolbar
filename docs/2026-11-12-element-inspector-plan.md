# Element inspector plan

Pick an element on the host page and the panel jumps to what the toolbar knows
about it: the LiveView or LiveComponent that owns it, its component tree node,
the HEEx source that rendered it (from LiveView's debug annotations) and the
event its `phx-*` binding sends. Reverse direction: hovering a component tree
node outlines its element on the page. New ADR 16.

Two implementation tasks, one commit each, tests first. Both run code in the
host page or take host DOM text as input: each gets a combined reviewer.

## Message contract (fixed, both tasks code against it)

Panel to loader (`frame -> parent`, existing origin and source gate in
`assets/js/loader.js` around line 397):

- `pdt:pick` `{}`: arm pick mode (a second `pdt:pick` while armed disarms).
- `pdt:highlight` `{root: string, cid: integer | null}`: outline the element of
  the LiveView root whose DOM id is `root` (`cid: null`) or the
  `[data-phx-component="<cid>"]` element inside it. `{root: null}` clears.

Loader to panel (existing `post/2`, `assets/js/loader.js` around line 226):

- `pdt:picking` `{armed: boolean}`: pick mode state, for the button's `aria-pressed`.
- `pdt:inspect` `{inspected: payload}`, payload (every string truncated, see caps):

```js
{
  root: "phx-F..." | null,      // id of the closest [data-phx-session] (a LiveView root)
  cid: 3 | null,                // closest [data-phx-component], integer
  tag: "button",                // lower case tag name
  tag_line: 42 | null,          // data-phx-loc on the element, integer
  binding: {event: "phx-click", name: "save", target: "#x" | "3" | null} | null,
  frames: [{name: "DemoWeb.CoreComponents.button", file: "lib/x.ex", line: 12}],
                                // innermost first, open function components around the element
  caller: {file: "lib/y.ex", line: 34} | null // @caller of the innermost frame
}
```

Panel hook to server: `pushEvent("pdt:inspect", payload)`.

Caps (both sides enforce; the server never trusts the client's): at most 200
nodes visited by the walk, 20 frames, strings at most 512 bytes, lines and cid
integers in `0..10_000_000`.

## Tasks

### T1: picker and highlight in the loader (ADR 04, 16)

- `assets/js/inspect.mjs` (pure, no globals): `resolve(element)` builds the
  payload. Walk from the element up to the LiveView root (`document.body` for a dead render; the root's own siblings are not scanned, so a nested LiveView never sees its parent's frames): on each level scan
  previous siblings for comment nodes; `<!-- <Mod.fun> file:line (app) -->` opens
  a frame unless a matching `<!-- </Mod.fun> -->` was seen later on the same level
  (closed before the element); `<!-- @caller file:line (app) -->` right before an
  open frame is that frame's caller. Slot annotations (`<:name>`) are skipped.
  The binding is the closest element (self or ancestor, inside the root) with
  `phx-click`, `phx-submit` or `phx-change`, with its `phx-target`.
  Also `outlineBox(element)`: the rect to draw.
- `assets/js/loader.js`: on `pdt:pick` arm: capture-phase `pointermove`
  (one resolve per animation frame), `click`, `keydown` (Esc) listeners on
  `document`, plus `pointerdown`/`mousedown`/`pointerup`/`mouseup` swallowed (no focus, no host drag logic); a panel iframe reload disarms; an outline box plus a label (tag, innermost frame name) in the
  shadow root, `pointer-events: none`. While armed the click is
  `preventDefault` + `stopPropagation` (never reaches host handlers), posts
  `pdt:inspect`, disarms, and opens the panel (`setState("open")`). Disarm
  removes every listener and the box. Clicks inside our own host element are
  ignored (they are the toolbar). `pdt:highlight` draws the same box, no
  listeners; it clears on the next `pdt:highlight` with `root: null`, on
  scroll, and after 3 s.
- Tests: `assets/js/test/inspect.test.mjs` (open/closed frames, caller,
  slots, bindings, caps, no annotations), loader wiring in
  `assets/js/test/loader.test.mjs` (arm, click posts and disarms, Esc, host
  handlers not reached while armed, listeners gone after disarm, highlight).
  Extend `assets/js/test/support/fake_dom.mjs` with comment nodes,
  `previousSibling`, `parentNode`, `getBoundingClientRect` as needed.
- `mix assets.build`, commit `priv/static`.

### T2: panel side (ADR 07, 16)

- `assets/js/panel.js`: a header button `#pdt-pick` (aria-pressed from
  `pdt:picking`) sends `pdt:pick`; `pdt:inspect` from the loader is pushed to the
  server through `PdtPanel` (buffered until the hook mounts, like client events);
  `pointerenter`/`pointerleave` on `[data-pdt-root]` tree rows send
  `pdt:highlight`. Hidden in the standalone panel (`pdt-standalone`).
- `PhoenixDevToolbar.Inspected` (`@moduledoc false`): `parse/1` validates the
  untrusted payload into a struct (caps above, strings only, never atoms;
  invalid fields dropped, never a raise), plus `editor_url/2` from `PLUG_EDITOR`
  (`__FILE__` absolute from `File.cwd!/0`, `__LINE__`; only a relative file
  without `..`; no link when unset or when the template starts with
  `javascript:`).
- `PanelLive` `handle_event("pdt:inspect", ...)`: parse, open the LiveView tab,
  `Panel.send_now` `{:inspect, inspected}` to its component.
- `Panels.LiveView`: on `{:inspect, i}` switch to Components (or Assigns when
  `cid` is nil and the root is the page's own LiveView), keep the inspected
  element, show an "Inspected element" strip `#pdt-inspected` above the sub-tab:
  tag and line, binding, frames with editor links, caller. The node whose
  root and cid match gets `aria-current="true"` and is scrolled into view.
  Dead render (no root): the strip only.
- `ComponentTree`: each view gets `root` (the DOM id: the label's topic
  without its `lv:` prefix, through a new `LiveViewCompat.live_view_topic/1` or
  by widening `live_view_label/1`); rows render `data-pdt-root` and
  `data-pdt-cid`.
- `dev.exs`: `config :phoenix_live_view, debug_heex_annotations: true,
  debug_attributes: true` (as a Phoenix 1.8 app has in dev).
- Tests: `test/phoenix_dev_toolbar/inspected_test.exs` (parse caps, garbage,
  editor URL), LiveView panel test (inspect event selects the node, strip
  shown, dead render), `component_tree_test` (root id),
  `assets/js/test/panel.test.mjs` (button, forward, hover).

### T3: docs (orchestrator)

ADR 16 "Element Inspector", ADR 07 and ADR 04 cross-links, README section and
screenshot (`media/`), CHANGELOG lines, roadmap entry.

## Risks

- **Host isolation (ADR 04)**: listeners exist only while armed and are removed
  on disarm; the box lives in our shadow root; nothing touches `liveSocket` or
  host elements. A swallowed click while armed is the point; unarmed, nothing is
  intercepted. Covered by loader tests.
- **Hot path**: nothing server side runs in host processes; the root id comes
  from the process label the tree read already fetches.
- **Memory bounds**: walk and payload caps on both sides; one inspected element
  kept in the component's assigns.
- **Untrusted input**: host DOM text crosses into the server: `Inspected.parse/1`
  is the only entry, strings bounded, integers ranged, no atoms; editor links
  built only from validated relative paths.
- **Public API**: no new config; `PLUG_EDITOR` is Phoenix's convention.
  Degrades without annotations (strip says which two flags turn them on).
- **Tests and ADR sync**: as listed per task; ADR 16 new, ADR 07 updated.

## Follow-ups from the feature reviews

- Walk budget configurable: `inspect_nodes:` (default 500, 50 to 10_000), sent as
  `data-pdt-inspect-nodes`; the payload carries `truncated` and the strip says when
  the walk stopped early (ADR 16).
- Pick mode listens on `window` in the capture phase with
  `stopImmediatePropagation`, and also swallows `dblclick`, `auxclick`,
  `contextmenu` and touches; Esc in the panel is forwarded.
- A pick in a LiveView outside the page's tree (a sticky `live_render`) shows the
  strip only, with a hint.
- `#pdt-pick` is a crosshair icon in the collapsed bar and the open panel, shown
  only with the LiveView tab on; a pick from the collapsed bar opens the panel at
  the right sub-tab.
