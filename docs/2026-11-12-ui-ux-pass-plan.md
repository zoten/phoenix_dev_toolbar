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

### Batch A tasks

Branch `ui-pass-batch-a`, one commit per task. Each task is implemented by one agent and
reviewed by one reviewer; the batch ends with a feature review over its commit range.

**A1: asset ETag and 304** (`lib/phoenix_dev_toolbar/plug.ex` `serve_asset/2`,
`test/phoenix_dev_toolbar/plug_test.exs` `describe "assets"`, about line 373).

- Tests first, in the `"assets"` describe: every whitelisted asset carries one weak
  `etag` (`W/"..."`) and still `cache-control: no-cache`; the same ETag twice in a row;
  a request with that value in `if-none-match` gets `304`, an empty body, the same
  `etag` and `cache-control`, and halts; a stale value, a list holding the value
  (`W/"x", <etag>`), the strong form of the value (`"..."` without `W/`), and `*` behave
  as RFC 9110 weak comparison says (match: list member, strong form, `*`; no match:
  stale); a 404 has no `etag`.
- Implementation: `File.stat(path, time: :posix)` replaces `File.regular?/1` (a
  directory or a missing file stays a 404); ETag `W/"<size>-<mtime>"`; parse
  `if-none-match` by splitting on commas and stripping `W/` and spaces, never creating
  atoms. A 304 goes through `Conn.send_resp(304, "")` and keeps `x-content-type-options`.
  The request stays `untracked/1` as today.
- ADR 04 "Assets" bullet: one sentence on revalidation (weak ETag from size and
  mtime, 304, `no-cache` kept so a rebuilt bundle or a bumped dep shows at once).
- CHANGELOG: `- Panel assets revalidate with an ETag: 304 instead of a full download (ADR 04)`.
- Verify: `mix test test/phoenix_dev_toolbar/plug_test.exs`, `mix compile --warnings-as-errors`,
  `mix credo --strict lib/phoenix_dev_toolbar/plug.ex`.

**A2: panel scrolling and long lists** (`assets/css/panel.css`, `priv/static/panel.css`).

- `.pdt-section`: `overscroll-behavior: contain; scrollbar-gutter: stable`.
- Dark mode block: `scrollbar-color: var(--pdt-border) transparent` on `.pdt-section`
  (light keeps the browser default).
- `.pdt-row`: `content-visibility: auto; contain-intrinsic-size: auto 48px`. Paint
  containment clips what overflows a row: grep the classes used inside rows
  (`grep -rn 'pdt-row' lib`) for absolute or negative-margin children that leave the
  row box (`.pdt-plan__hide` stays inside). Only `li` and `div` rows, no table rows.
- `mix assets.build` (dev env) and commit `priv/static/panel.css`.
- CHANGELOG: `- Panel lists: no scroll chaining into the page, off-screen rows skipped (ADR 04)`.
- Verify: `mix test.js`, `mix test test/phoenix_dev_toolbar/layouts_test.exs`, and
  `MIX_ENV=dev mix assets.build && git diff --exit-code priv/static` after the commit.
  By hand (orchestrator, `mix dev`): scroll the Ecto list past its end (the page must not
  move), EXPLAIN then Hide with the keyboard (focus comes back), find-in-page reaches an
  off-screen row, dark mode scrollbar.

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

### Batch B tasks

Branch `ui-pass-batch-b`, one commit per task, an Opus reviewer per task, a feature
review at the end. Colors below are measured (scratchpad script, WCAG relative
luminance) against `--pdt-bg`, `--pdt-bg-alt` and `--pdt-error-bg` of each mode.

**B1: contrast tokens and a contrast guard** (`assets/css/panel.css` `:root` and the
dark block at the top, the rules listed below; new `assets/js/contrast.mjs`,
`assets/js/test/contrast.test.mjs`).

- Guard first: `contrast.mjs` exports pure helpers (`parseHex`, `luminance`,
  `ratio`, `mix(a, b, weight)` for the `color-mix(in srgb, ...)` and opacity cases).
  `contrast.test.mjs` reads `assets/css/panel.css` with `node:fs`, extracts the custom
  properties of `:root` and of the `prefers-color-scheme: dark` block (a small regex
  over `--pdt-*: #xxxxxx;`, dark overrides light), and asserts each text pair below
  reaches 4.5:1 in both modes. The module is not imported by `loader.js` or
  `panel.js`, so it never reaches a bundle. Write it against today's CSS and see it fail.
- Pairs (text on background): `--pdt-muted`, `--pdt-accent-text`, `--pdt-ok`,
  `--pdt-warn`, `--pdt-error`, `--pdt-code` on each of `--pdt-bg`, `--pdt-bg-alt`,
  `--pdt-error-bg`; `#fff` on `--pdt-error-fill`; `--pdt-header-fg`,
  `--pdt-header-warn`, `--pdt-header-error`, `--pdt-accent` (the logo) on `--pdt-header`.
- Token values:

  | Token | Light | Dark |
  |---|---|---|
  | `--pdt-accent-text` (new) | `#c43c00` | `#fd4f00` |
  | `--pdt-ok` | `#187a45` | `#1f9d55` |
  | `--pdt-error` (text, stripes) | `#c53030` | `#f07171` |
  | `--pdt-error-fill` (new, badge background) | `#c53030` | `#c53030` |
  | `--pdt-header-error` (new) | `#ff8a8a` | `#ff8a8a` |
  | `--pdt-muted` | darkest needed for 4.5:1 on `--pdt-error-bg` (about `#626977`) | unchanged |

- Rules: accent as text (`.pdt-method`, `.pdt-pid-link code`, `.pdt-pushed`,
  `.pdt-tag--client`) uses `--pdt-accent-text`; borders, focus rings, the sparkline,
  `.pdt-snapshot--changed` and the resize handle keep `--pdt-accent`. `.pdt-logo` keeps
  `--pdt-accent` (on the header). `.pdt-badge--error` background uses
  `--pdt-error-fill`; `.pdt-tab--error` uses `--pdt-header-error`. Noise rows:
  `.pdt-row--noise` drops `opacity` for `color: var(--pdt-muted)` on the row and its
  `.pdt-sql` (and the hover/focus-within rule goes). Grep `var(--pdt-accent)` and
  `var(--pdt-error)` to catch any other text use.
- The loader's pill (`assets/js/loader.js` `STYLE`, `#fd4f00` on `#1f2330`, 4.69:1)
  already passes: no change.
- CHANGELOG: `- Panel colors reach WCAG AA contrast, checked by a JS test (ADR 04)`.
- Verify: `mix test.js`, `MIX_ENV=dev mix assets.build`, commit `priv/static/panel.css`.

**B2: forced colors, motion, small text, screen reader class** (`assets/css/panel.css`).

- `@media (forced-colors: active)` block at the end of the file: `.pdt-badge--ok`,
  `.pdt-badge--warn`, `.pdt-badge--error` get `border: 1px solid` (CanvasText or
  Highlight; error keeps a distinct `Mark`/`Highlight` choice) since inset shadows and
  backgrounds are dropped; `.pdt-row--error` and `.pdt-snapshot--changed` get
  `border-inline-start: 3px solid`; `.pdt-tab--active`, `.pdt-subtab--active`,
  `.pdt-dock-option[aria-pressed="true"]` get an underline or outline in `Highlight`
  (today only a background tells them apart); the dock icons draw their filled edge as
  a `border-*-width: 4px` instead of an inset shadow (one rule per edge, light and
  normal modes unchanged).
- `@media (prefers-reduced-motion: reduce)`: no transitions on `.pdt-tab` and
  `.pdt-toggle__icon` (the only two in the file; grep `transition`).
- `.pdt-button--small`: 10px to 11px (line height stays 16px, height 18px).
- `.pdt-sr-only`: `clip-path: inset(50%)` instead of `clip`, plus `margin: -1px;
  padding: 0; border: 0`.
- CHANGELOG: `- Panel: forced colors support, reduced motion, 11px minimum text (ADR 04)`.
- ADR 04: one bullet (in the panel UI part) stating the decision: tokens checked for AA
  by `contrast.test.mjs`, accent text vs accent fill, forced colors and reduced motion
  supported.
- Verify: `mix test.js`, `MIX_ENV=dev mix assets.build`, commit `priv/static/panel.css`.
  By hand (orchestrator, Chrome emulation): forced colors active, light and dark;
  reduced motion.

**B3: media** (orchestrator, `mix dev` in a browser at 1440x900, bottom dock unless the
shot is about docks, harness fixture data, PNG under ~300 KB).

- Retake the stills whose colors change: `hero.png`, `hero-dark.png`, `explain.png`,
  `query-error.png`, `liveview-profiler.png`, `liveview-assigns.png`,
  `liveview-events.png`, `liveview-components.png`, `process.png`, `system.png`,
  `dock-right.png`. Match the framing and state of the current file (open it first).
  `collapsed.png` and `hidden.png` show no changed color: keep them.
- `toolbar-demo.gif` stays (subtle shifts); retake it with the next visible feature.

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

### Batch C tasks

Three tasks on disjoint files, run in parallel, each in its own worktree branched from
`ui-pass-batch-c` and merged back. The orchestrator writes ADR 04 and CHANGELOG after
the merge (tasks do not touch them, so they never conflict). An Opus reviewer per task,
a feature review at the end, a hand check with a screen reader tree (Chrome DevTools
accessibility snapshot) and the keyboard.

**C1: panel semantics and focus** (`lib/phoenix_dev_toolbar/panel_layout.ex`,
`assets/js/panel.js`, `assets/js/test/panel.test.mjs`, `test/phoenix_dev_toolbar/panel_live_test.exs`
or the closest panel layout test; `priv/static/panel.js`).

- Toggle `#pdt-toggle`: `aria-expanded` set by `setOpen` in panel.js, label
  "Toolbar panel". The button is server rendered and LiveView patching drops attributes
  the server did not render: move `#pdt-hide` and `#pdt-toggle` into a wrapper with
  `phx-update="ignore"` (as `#pdt-dock-picker` already is; neither button has server
  state), and give the toggle a server rendered `aria-expanded="false"` start value.
  Check that `.pdt-standalone` CSS still hides them (selectors are by class).
- Dock menu: drop `aria-haspopup` from `#pdt-dock`; close the menu on `focusout` when
  `relatedTarget` is outside `#pdt-dock-picker` (no refocus).
- Tabs: `<nav role="tablist">` becomes `<div role="tablist" aria-label="Toolbar tabs">`
  (keep the class and id); `Home`/`End` in the tab keydown handler (first/last tab, focus
  and click like the arrows). The error state: a `<span class="pdt-sr-only">
  (disabled after an error)</span>` inside the tab when `tab_error/4` is set (C2 makes
  the CSS `" !"` visual only).
- Disconnected notice: `#pdt-offline` keeps its CSS display but drops `role="status"`
  and gets `aria-hidden="true"`; a new empty `<span id="pdt-live-status"
  class="pdt-sr-only" role="status" phx-update="ignore">` in the header; the `PdtPanel`
  hook's `disconnected()` writes "Toolbar disconnected: what it shows is frozen until it
  reconnects" there and `reconnected()` writes "Toolbar reconnected" (cleared after 3s).
- Focus on show (panel half of the loader's C3): a `pdt:focus` message from the parent
  (same origin and source checks as `pdt:state`) focuses `#pdt-toggle`.
- Tests: panel.test.mjs (aria-expanded follows pdt:state, Home/End, focusout closes the
  menu, pdt:focus from parent focuses the toggle and from another source does nothing,
  live status text on disconnected/reconnected); a LiveView test for the tablist markup,
  the sr-only error text and the ignored wrapper ids. Extend `fake_dom.mjs` if needed.

**C2: information in titles, focus rings** (`lib/phoenix_dev_toolbar/components.ex`,
`assets/css/panel.css`, `test/phoenix_dev_toolbar/components_test.exs`; `priv/static/panel.css`).

- `summary_bar/1`: a badge with a `title` also renders it as
  `<span class="pdt-sr-only">: {title}</span>`; same for the dropped and trimmed badges.
- `phase_tag/1` (HTTP, live), the `framework` and `task` tags and the `N+1` tag in
  `query_row/1`: the explanation as `pdt-sr-only` text after the visible label. `title`
  stays for mouse users.
- `.pdt-tab--error::after`: `content: " !" / ""` (alternative text syntax), so screen
  readers read C1's sr-only text instead of the `!`.
- Focus rings: one shared `:focus-visible` rule (outline 2px `--pdt-accent`, offset 1px)
  replacing the per-class rules, covering also `.pdt-crumb`, `.pdt-export input`,
  `.pdt-actions__kill select`, `.pdt-pid-link`. Inputs and textareas keep offset 0.
- Tests: components_test (sr-only text present for a titled badge and for each tag),
  contrast.test.mjs still green.

**C3: loader focus and resize handle** (`assets/js/loader.js`,
`assets/js/test/loader.test.mjs`; `priv/static/loader.js`).

- Hide: on `pdt:hide`, when focus is in our frame (`root.activeElement === frame`, the
  shadow root's), focus the pill after it shows. Otherwise leave focus alone.
- Show: the pill's click, after `setState("collapsed")`, focuses the frame
  (`frame.focus()`) and posts `pdt:focus` (C1 handles it).
- Handle: hit area 12px (`height`/`width` and the `calc(var(--pdt-extent) - 6px)` offsets),
  the visible `::after` bar unchanged; `aria-valuetext` "<n> pixels" next to
  `aria-valuenow` in `applySize`.
- Tests: loader.test.mjs (focus moves to the pill only when the frame had focus; pill click
  posts pdt:focus; valuetext follows resizes). Extend `fake_dom.mjs` for shadow root
  `activeElement` if needed (it has `attachShadow` and `focus`).

## Batch D: theme, pill corner, shortcut

- **Theme** (dock menu, per browser): an "Auto / Light / Dark" choice under the
  reserve toggle, stored in the loader's `pdt:layout` (`theme`, `layout.mjs`
  `parseLayout`/`serializeLayout`, unknown values fall back to auto) and sent with
  `pdt:state`. panel.js sets `data-theme` on the iframe root; `panel.css` tokens move
  to `light-dark()` with `color-scheme` driven by `:root[data-theme]` (auto keeps
  `light dark`). No config key. The loader's pill and handle stay as they are: like the
  panel header, they are dark in both themes.
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

### Batch D tasks

D1 and D2 run in parallel (disjoint files, in their own worktrees branched from
`ui-pass-batch-d`); D3 starts after D2 is merged, since both touch `loader.js` and
`panel.js`. The orchestrator writes ADR 04, README and CHANGELOG after the merges. An
Opus reviewer per task, a feature review at the end, a hand check in `mix dev`.

Contract between the tasks (fixed here so they can run in parallel):

- Loader tag attributes, written only when set and valid: `data-pdt-pill` with one of
  `bottom-right`, `bottom-left`, `top-right`, `top-left` (absent means bottom right), and
  `data-pdt-shortcut` with the canonical combo: lowercase, modifiers in the order
  `ctrl`, `alt`, `shift`, `meta`, joined by `+`, then the key (`a`..`z`, `0`..`9` or
  `f1`..`f12`), for example `ctrl+shift+d`.
- `pdt:state` gains `shortcut` (the canonical string or `null`), and with D3 `theme`
  (`"auto"`, `"light"`, `"dark"`). The panel posts `pdt:theme` with `{theme}`.

**D1: config and loader tag** (`lib/phoenix_dev_toolbar/config.ex`,
`lib/phoenix_dev_toolbar/plug.ex` `loader_tag/3` about line 498,
`lib/phoenix_dev_toolbar/application.ex` next to `Config.warn_mcp()` about line 128,
`test/phoenix_dev_toolbar/config_test.exs`, `test/phoenix_dev_toolbar/plug_test.exs`).

- `Config.pill_corner/0 :: :bottom_right | :bottom_left | :top_right | :top_left`
  (invalid or unset: `:bottom_right`, never logs) and `Config.shortcut/0 :: String.t() | nil`
  (the canonical combo per the contract; accepts any case, spaces around `+`, `cmd` as
  an alias of `meta`, `control` of `ctrl`, `option` of `alt`; needs at least one
  modifier and exactly one key; anything else, including non binaries, is `nil`).
  Both total functions over any term: they never raise.
- `Config.warn_ui/0`, called at boot next to `warn_mcp/0`: one warning per invalid
  `pill_corner:` or `shortcut:` value, saying what is expected and what is used instead.
- `loader_tag/3`: `data-pdt-pill` only when not the default, `data-pdt-shortcut` only
  when set. This runs inside the host's request (before_send): no logging there, one
  `Application.get_env` per key as `reserve_space?/0` does.
- Tests first: config_test (each corner, invalid corner, unset; shortcut canonical forms,
  aliases, order, invalid inputs: no modifier, two keys, unknown key, `""`, an atom, a
  list; `warn_ui` logs with `capture_log` and stays silent when valid); plug_test
  (attributes present and escaped, absent by default; use the file's env helper to set
  and restore app env).

**D2: pill corner and shortcut in the browser** (`assets/js/loader.js`, `assets/js/panel.js`
(only the `pdt:state` handling and a keydown listener), new `assets/js/shortcut.mjs`,
`assets/js/test/shortcut.test.mjs`, `assets/js/test/loader.test.mjs`,
`assets/js/test/panel.test.mjs`; `priv/static/loader.js`, `priv/static/panel.js`).

- `shortcut.mjs` (pure): `parseShortcut(string) -> {ctrl, alt, shift, meta, code} | null`
  for the canonical form, mapping the key to `KeyboardEvent.code` (`d` -> `KeyD`,
  `1` -> `Digit1`, `f5` -> `F5`: physical keys, so Alt combos work on macOS where
  `event.key` changes); `matches(spec, event)` checks every modifier exactly;
  `editable(target)` true for `input`, `textarea`, `select` and `isContentEditable`.
- Loader: reads `data-pdt-shortcut` once; when valid, one `window` `keydown` listener
  (capture false, inside `try/catch`, never `preventDefault` unless it matches; skips
  `event.repeat`, `event.isComposing`, editable targets). On match: hidden becomes
  collapsed, otherwise open and collapsed swap. `pdt:state` carries `shortcut`. The
  pill's `title` adds the combo ("Show the dev toolbar (Ctrl+Shift+D)").
- Loader: `data-pdt-pill` sets one `corner-<name>` class on the pill (unknown values
  ignored); `STYLE` positions each corner with the existing 12px offsets.
- Panel: on `pdt:state` keeps the shortcut; its own `keydown` listener (same skips)
  posts `pdt:toggle` on a match, so the combo works with focus inside the toolbar; the
  hide button's `title` adds the combo.
- Tests first: shortcut.test (parse, codes, modifiers exact, editable targets), loader
  (no listener without the attribute, toggles, hidden to collapsed, skips inputs and
  repeats, corner class, title), panel (match posts `pdt:toggle`, skip in the Eval
  textarea, no shortcut: nothing).

**D3: theme** (`assets/js/layout.mjs`, `assets/js/loader.js`, `assets/js/panel.js`,
`lib/phoenix_dev_toolbar/panel_layout.ex` dock menu, `assets/css/panel.css`,
`assets/js/test/contrast.test.mjs` and the layout, loader, panel tests;
`priv/static/*`).

- `layout.mjs`: `theme` in the layout (`"auto"` default, unknown values read as auto,
  old layouts without it read as auto; serialized only when not auto).
- Loader: `pdt:state` carries `theme`; a `pdt:theme` message (known values only) saves
  it and answers with `pdt:state`.
- Dock menu (`panel_layout.ex`, inside the ignored `#pdt-dock-picker`): after the
  reserve toggle, a separated group labelled "Theme" with three `pdt-dock-option`
  buttons `#pdt-theme-auto|light|dark` (`data-pdt-theme`, `aria-pressed`).
  panel.js sets `data-theme` on `<html>` (none for auto) and the pressed state from
  `pdt:state`, and posts `pdt:theme` on click. Standalone (no loader): read the theme
  from `localStorage` `pdt:layout` (same origin) with `parseLayout`.
- `panel.css`: each token that differs by mode becomes `light-dark(<light>, <dark>)` in
  `:root`; `:root { color-scheme: light dark }`, `:root[data-theme="light"] {
  color-scheme: light }`, `:root[data-theme="dark"] { color-scheme: dark }`; the
  `prefers-color-scheme: dark` token block goes (the dark `scrollbar-color` rule becomes
  `light-dark(...)` too). Forced colors and reduced motion blocks unchanged.
- `contrast.test.mjs`: reads `--pdt-x: light-dark(#l, #d)` and plain `#x` tokens (both
  modes) from `:root`, keeps every existing assertion (formats, brace balance, accent
  as text) and fails if a checked token is missing in either mode.
- Tests: layout (theme round trip, legacy), loader (`pdt:theme` saved and echoed,
  unknown ignored), panel (data-theme applied, pressed state, click posts), and a
  LiveView test for the three menu buttons.

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
