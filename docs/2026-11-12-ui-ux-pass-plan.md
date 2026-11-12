# UI and UX pass

A frontend review of the toolbar (loader, panel iframe, CSS, panel markup) against
modern web practice, performance, design and accessibility (WCAG 2.2 AA). The
isolation model, keyboard resize, roving tab focus and our own bundle size (about
11.5 KB gzipped) are fine. This pass fixes what a user can feel (asset reloads,
scroll chaining, contrast), then the accessibility gaps, then small CSS upgrades.
Batch D adds a theme choice and two config keys
(`pill_corner:`, `shortcut:`), decided with the maintainer: new public options, no break.

Line numbers are from commit 4c5dd4d and drift as batches land: search, do not trust them.

## Batch A: performance quick wins

- **Asset revalidation** (`lib/phoenix_dev_toolbar/plug.ex` `serve_asset/2`, about
  line 546): assets are sent with `cache-control: no-cache` and no validator, so
  every host page load downloads `phoenix.js` (28 KB) and `live_view.js` (125 KB)
  again in full. Add a weak `ETag` from the file's `File.stat` (mtime and size), answer
  `304` on a matching `if-none-match`, keep `no-cache` (a rebuilt bundle or a bumped
  dep is picked up at once). No fingerprinted URLs: the host's own Phoenix and
  LiveView files can change under us.
- **Scroll chaining**: `overscroll-behavior: contain` on `.pdt-section`
  (`assets/css/panel.css`): scrolling a list past its end no longer scrolls the host page.
- **Long lists**: `content-visibility: auto; contain-intrinsic-size: auto 48px` on
  `.pdt-row`. Check that `data-pdt-keep-focus` restore and find-in-page still work.
- **Scrollbars**: `scrollbar-gutter: stable` on `.pdt-section`; `scrollbar-color`
  from the tokens in dark mode.
- Tests: `plug_test.exs` (ETag present, 304 on match, 200 on mismatch, unknown asset
  still 404).

## Batch B: color, contrast and forced colors

Measured ratios (AA needs 4.5:1 for text, 3:1 for focus rings and UI parts):

| Pair | Now |
|---|---|
| accent `#fd4f00` on white (`.pdt-method`, `.pdt-pid-link`, `.pdt-pushed`, `.pdt-tag--client`) | 3.34 |
| ok `#1f9d55` on white (`.pdt-tag--live`) | 3.49 |
| error `#d64545` on white / on `--pdt-error-bg` / white on the error badge | 4.38 / 3.97 / 4.38 |
| error tab on the header (`.pdt-tab--error`) | 3.58 |
| noise rows (`.pdt-row--noise`, opacity .55) | 2.15 |

- New token `--pdt-accent-text` (about `#c43c00` light, `#fd4f00` dark) for accent
  text; `--pdt-accent` stays for fills, focus rings and the sparkline. Darken
  `--pdt-ok` and `--pdt-error` in light mode, add a header-specific
  `--pdt-header-error` (on `#1f2330` and `#0f1117`). Every pair above reaches 4.5:1,
  checked with a small script (scratchpad, not committed).
- Noise rows: mute with `color: var(--pdt-muted)` on the row and its code instead of
  `opacity`.
- **Forced colors**: inset `box-shadow` disappears in Windows High Contrast. Add a
  `@media (forced-colors: active)` block: real borders for `.pdt-badge--ok/--warn`,
  `.pdt-row--error`, `.pdt-snapshot--changed`; the dock icons' filled edge as a
  `border-*-width` instead of a shadow.
- `prefers-reduced-motion: reduce` in `panel.css` (tab, toggle icon transitions);
  the loader already has it.
- Smallest text: `.pdt-button--small` goes from 10px to 11px.
- `.pdt-sr-only`: `clip-path: inset(50%)`, plus `margin: -1px; padding: 0; border: 0`.
- Media: retake `hero.png`, `hero-dark.png`, `query-error.png`, `explain.png`,
  `liveview-*.png`, `process.png` (accent text and error colors change).

## Batch C: accessibility semantics and focus

All in `lib/phoenix_dev_toolbar/panel_layout.ex`, `components.ex`,
`assets/js/panel.js`, `assets/js/loader.js`; DOM tests on the fake DOM
(`assets/js/test/panel.test.mjs`, `loader.test.mjs`) plus LiveView tests.

- **Collapse toggle** `#pdt-toggle`: `aria-expanded` set by `setOpen` in panel.js
  (the label becomes "Toolbar panel": the state is now announced).
- **Dock menu**: drop `aria-haspopup` (it promises `role="menu"`); keep a disclosure
  (`aria-expanded` + `aria-controls`) over a group of toggle buttons. Close on
  `focusout` leaving the picker. Popover API and anchor positioning are deferred (below).
- **Tabs**: `Home`/`End` in the tab keydown handler; `<nav role="tablist">` becomes a
  `<div role="tablist" aria-label="Toolbar tabs">`; the error state moves from the CSS
  `" !"` to a `pdt-sr-only` "(disabled after an error)" inside the tab, the `!`
  stays visual (`aria-hidden`).
- **Focus on hide and show** (loader): `pdt:hide` moves focus to the pill when focus
  was in the frame; the pill's click focuses the frame. No focus move when focus was
  elsewhere in the host page.
- **Information only in `title`**: badges (`summary_bar`), `phase_tag`, `framework`,
  `task` and `N+1` tags get the explanation as `pdt-sr-only` text, as the N+1 count
  badge already does. `title` stays for mouse users.
- **Missing `:focus-visible`**: `.pdt-crumb`, `.pdt-export input`,
  `.pdt-actions__kill select`. One shared selector list instead of one rule per class.
- **Disconnected notice**: `#pdt-offline` is a CSS shown `role="status"`, which
  screen readers often skip. The `PdtPanel` hook's `disconnected()`/`reconnected()`
  callbacks write and clear the text of an empty live region instead.
- **Resize handle** (loader `STYLE`): hit area 12px (the visible bar stays 4px, via
  `::after`), `aria-valuetext` "<n> pixels".

## Batch D: theme, pill corner, shortcut

- **Theme** (dock menu, per browser): an "Auto / Light / Dark" choice under the
  reserve toggle, stored in the loader's `pdt:layout` (`theme`, `layout.mjs`
  `parseLayout`/`serializeLayout`, unknown values fall back to auto) and sent with
  `pdt:state`. panel.js sets `data-theme` on the iframe root; `panel.css` tokens move
  to `light-dark()` with `color-scheme` driven by `:root[data-theme]` (auto keeps
  `light dark`). No config key. The loader's own pill and handle follow the same
  choice (the pill colors come from tokens in `STYLE`).
- **Pill corner** (`pill_corner:`, app env like `reserve_space:`): one of
  `:bottom_right` (default), `:bottom_left`, `:top_right`, `:top_left`. `Config`
  validates it (unknown value: log once, use the default); the plug writes it as
  `data-pdt-pill` on the loader tag; `STYLE` gets one class per corner. Atoms from the
  config only, never from the attribute.
- **Shortcut** (`shortcut:`, off by default): a string such as `"ctrl+shift+d"`,
  validated and normalized by `Config` (modifiers `ctrl`, `alt`, `shift`, `meta`, plus
  one key; at least one modifier). Written as `data-pdt-shortcut`; the loader parses it
  once, listens on `window` `keydown` (passive, `try/catch`), skips `event.repeat`,
  `isComposing`, and targets that are `input`, `textarea`, `select` or
  `contenteditable`, then toggles: collapsed or open flips, hidden shows the bar.
  The panel iframe forwards the same combo with `pdt:toggle`, so it works with focus
  inside the toolbar too. The hide button's `title` and the pill's mention the combo.
- Tests: `config_test.exs` (valid, invalid, default for both keys), `plug_test.exs`
  (attributes on the loader tag, absent when unset), `layout.test.mjs` (theme
  round trip, legacy layout), `loader.test.mjs` (pill corner class, shortcut toggles,
  ignored in inputs and when unset), `panel.test.mjs` (theme applied, menu pressed state).
- Docs: README configuration section, `Config` `@doc`s, ADR 04 (theme, pill,
  shortcut). Media: retake `hidden.png` if the default corner render changes (it does
  not), add a dark-themed shot only if `hero-dark.png` no longer matches.

## Risks

- **Hot path**: none. The plug change is on the toolbar's own asset route, never on a
  host request; `File.stat` is one syscall the `send_file` already pays.
- **Production footprint**: unchanged, all code is behind the existing plug gate.
- **Host conflicts**: the loader changes (handle size, focus moves) run in the shadow
  root and only move focus out of or into our own frame. The handle's larger hit area
  overlaps 6px more of the host page edge while open: keep `touch-action: none` and
  check host scrollbars in a side dock by hand.
- **Caching**: a weak ETag from mtime and size misses a same-size rebuild within one
  second. Acceptable in dev; `mix assets.build` changes size in practice.
- **`content-visibility`**: can break `scrollIntoView` and focus restore on rows not
  rendered yet. Check EXPLAIN focus restore and the LiveView events stream by hand; drop
  it if either regresses.
- **Shortcut on the host page**: the listener runs in the host's keydown dispatch:
  never throws, never calls `preventDefault` unless the combo matches, and is not
  attached at all without `shortcut:`. A host that already binds the combo loses it
  only if the developer chose it.
- **Public API**: two new config keys and a theme value in `pdt:layout`; CHANGELOG
  lines; an old stored layout without `theme` reads as auto.
- **Tests and ADR sync**: ADR 04 (asset caching, the handle, focus on hide, forced
  colors and contrast tokens). CHANGELOG: two or three lines. `mix test.js` for the
  loader and panel changes; `mix assets.build` and commit `priv/static`.
- **Review**: one combined reviewer for Batch A (plug) and Batches C and D (loader, in
  the host page); Batch B is covered by the final review and a visual check in `mix dev`
  (light, dark, forced colors emulation).

## Deferred

- Dock menu on the Popover API with CSS anchor positioning, replacing
  `placeDockMenu`: wait for anchor positioning in every browser the toolbar supports.
- Base font in `rem` so the user's browser font size applies.
- Animating the frame with `clip-path` instead of `height`/`width` (120ms, minor).
- One convention for physical vs logical CSS properties.
