# ADR 16: Element Inspector

**Status:** Implemented (2026-11-12)  
**Area:** ui  
**Related:** [ADR 04](./04-ui-delivery.md) (loader, bridge, host isolation), [ADR 07](./07-live-view-panel.md) (component tree and assigns it jumps to)

## Context

A developer looking at a page asks "what rendered this element, and what does it
do". The source half is in the page already: LiveView's `debug_heex_annotations`
wrap each function component in HTML comments with its file and line, and
`debug_attributes` put `data-phx-loc` on every tag (both on by default in a
Phoenix 1.8 app's dev config). The runtime half is in the toolbar: the LiveView or
LiveComponent that owns the element, its assigns and its place in the component
tree. Picking an element joins the two.

## Decision

**Picking (loader).** The header's pick button (`#pdt-pick`, a crosshair icon
labelled "Pick an element (Esc cancels)", in the collapsed bar and the open panel)
sends `pdt:pick`; the loader arms pick mode and answers `pdt:picking {armed}`. While
armed, capture phase listeners on `window` (`pointermove`, `click`, `dblclick`,
`pointerdown`, `mousedown`, `pointerup`, `mouseup`, `auxclick`, `contextmenu`,
`touchstart`, `touchend`, `keydown`) outline the element
under the pointer (one resolve per animation frame) in a box drawn in the loader's
shadow root (`pointer-events: none`), and swallow presses and the click
(`preventDefault` plus `stopImmediatePropagation`; a touch is prevented only when
cancelable) so the host's handlers do not see them. Events
on the toolbar's own element are left alone. A click posts `pdt:inspect`, disarms
and opens the panel (from the collapsed bar too) at the right sub-tab; Esc (in the host page, or in the panel, which forwards it), a
second `pdt:pick` or a panel reload disarms. The button is shown only when the
LiveView tab is on. Disarmed,
no listener is attached to the host page.

**Resolving (`assets/js/inspect.mjs`).** A pure function turns the element into:

- `root`: the id of the closest `[data-phx-session]` (the LiveView's socket id);
- `cid`: the closest `[data-phx-component]` inside that root, as an integer;
- `tag`, `tag_line` (`data-phx-loc`);
- `binding`: the closest `phx-click`, `phx-submit` or `phx-change` (with `phx-target`) inside the root;
- `frames`: the function components still open around the element, innermost
  first, from the annotation comments of preceding siblings on each ancestor
  level, stopping at the LiveView root (the body for a dead render); slot
  annotations are skipped;
- `caller`: the `@caller` comment right before the innermost frame.

At most `inspect_nodes:` nodes visited (500 by default, 50 to 10_000, written as
`data-pdt-inspect-nodes` on the loader tag when not the default; `truncated: true`
when the budget runs out before the root), 20 frames, strings cut to 512 UTF-8 bytes (never
splitting a surrogate pair), integers in `0..10_000_000`.

**Panel.** `PanelLive` parses the payload with `PhoenixDevToolbar.Inspected.parse/1`
(the only entry for this host DOM text: the same caps again, unknown or invalid
fields dropped, never atoms, never a raise) and hands it to the LiveView tab, which
keeps one inspected element (cleared when the page changes) and shows the
"Inspected element" strip (`#pdt-inspected`): tag and line, binding, frames and
caller. A pick inside a LiveComponent or a nested LiveView opens the Components
sub-tab with that row selected (`aria-current`) and scrolled into view; a pick in
the page's own LiveView opens Assigns; a dead render shows the strip only. A pick whose root is no
view of the page's tree (a sticky `live_render` has a session of its own) shows the
strip only, with a hint, and selects nothing. Without annotations the strip names
the two config flags; with a truncated walk it names `inspect_nodes:` instead, or
notes that outer frames may be missing.

**Root ids.** Each component tree view carries its DOM id, the topic of the
`{Phoenix.LiveView, view, "lv:" <> id}` process label the tree read already
fetches (`LiveViewCompat.live_view_root/1`). Rows carry `data-pdt-root` and
`data-pdt-cid`.

**Highlight.** Hovering a tree row sends `pdt:highlight {root, cid}`; the loader
outlines that LiveView's root or its component (only one whose closest root is that
view: cids are per LiveView). It clears on leaving the row, on tab changes, on
collapse, on scroll and after 3 s.

**Editor links.** With `PLUG_EDITOR` set (Phoenix's convention, such as
`vscode://file/__FILE__:__LINE__`), frame and caller files become links: the file
made absolute against the working directory read when the pick arrives. A link is
built only for a relative path without `..` segments or backslashes, and a
template with a URL scheme other than `javascript`, `data`, `vbscript` or `file`.
The server never starts an editor.

## Consequences

- No host code changes and no new config: a Phoenix 1.8 app already emits the
  annotations in dev.
- The host pays nothing until the button is pressed; all work is in the browser.
- The dev harness turns both flags on for its `Demo*` templates (set after `lib/`
  compiles, so the toolbar's own templates stay unannotated there). In a host app
  that sets them, `debug_attributes` also adds `data-phx-pid` to every LiveView
  root, the panel's included: harmless.

## Open limits

- An element inside a slot reports the slot owner (`modal`) as the innermost frame,
  not the caller's template that wrote the slot content.
- Long lists: past `inspect_nodes:` previous siblings the walk stops; the strip
  says so and names the option.
- A host listener registered on `window` in the capture phase before pick mode is
  armed still runs first: listeners on one target run in registration order.
- A pick in a sticky LiveView shows the strip only: its assigns and tree live in
  another session.
- While armed, the outline does not follow scroll until the pointer moves.
- Elements inside host iframes cannot be picked.
- Pick mode stays armed if the toolbar is hidden mid-pick (Esc still disarms).
- Only `phx-click`, `phx-submit` and `phx-change` bindings are reported.
- Annotation paths outside the working directory (absolute) get no editor link.
- Umbrella apps: LiveView writes annotation paths relative to the app directory at
  compile time, while links join them to the runtime working directory (usually
  the umbrella root), so links can point to a missing file.
- `phx-click` holding a JS command shows its raw JSON in the strip.
- A pick in the page's own LiveView opens Components, not Assigns, until the tree has
  been read once: the root's DOM id comes from that read.
