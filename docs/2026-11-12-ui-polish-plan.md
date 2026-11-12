# UI polish: the UI pass's deferred items

The four items deferred by the [UI and UX pass](./2026-11-12-ui-ux-pass-plan.md), decided
with the maintainer: the dock menu moves to the Popover API with CSS anchor positioning
and the supported browsers are raised to match (one code path); font sizes follow the
user's browser setting; one convention for physical and logical CSS properties; the
frame animation is measured first and only changed if the trace shows a cost.

Line numbers are from commit 1f19c48 and drift as tasks land: search, do not trust them.

## Supported browsers

Anchor positioning is Baseline since January 2026: Chrome and Edge 125, Safari 26,
Firefox 147. The panel already needs Chrome 123, Firefox 120 and Safari 17.5 for
`light-dark()`; the floor becomes **Chrome 125, Firefox 147, Safari 26** (ADR 04 states it,
replacing the `light-dark()` line in "Open limits"). Older browsers still open the menu
(the popover shows in the top layer at its default place), mispositioned.

## Tasks

One branch `ui-polish`, one worktree per task where they run in parallel. E1 and E2 both
rewrite `panel.css`, so they run in sequence; E3 runs in parallel with them (it touches
only the dock menu rules, merged after); E4 is the orchestrator's measurement. An Opus
reviewer per task, a feature review at the end, `mix precommit` and `agent-tools/ci-min.sh`
before merging. The orchestrator writes ADR 04 and CHANGELOG after the merges.

**E1: font sizes in rem** (`assets/css/panel.css`, a new `assets/js/test/css_rules.test.mjs`;
`priv/static/panel.css`).

- Every `font`/`font-size` length becomes `rem` at today's 16px root (12px is `0.75rem`,
  11.5px `0.71875rem`, 11px `0.6875rem`, 16px `1rem`, 20px `1.25rem`), so a user who raised
  the browser's default font size gets larger panel text and the 16px default renders
  exactly as today.
- The header stays 34px tall: the loader sizes the collapsed iframe at `COLLAPSED_SIZE`
  (34px, `assets/js/layout.mjs`). Text inside the header and its 20px badges is capped,
  `min(0.75rem, 14px)` style, so a large browser font cannot overflow the collapsed bar.
  Line heights in the header stay in px; everywhere else they become unitless.
- `css_rules.test.mjs` (Node built-ins, reads `panel.css` like `contrast.test.mjs`): fails
  on a `font` or `font-size` declaration with a bare px size, except inside `min(...)`.
- Verify by hand: Chrome settings font size "Very large" (24px): content text scales, the
  collapsed bar keeps its height and badges stay inside it.

**E2: logical properties** (`assets/css/panel.css`, `assets/js/test/css_rules.test.mjs`;
`priv/static/panel.css`).

- Convention, stated in a comment at the top of `panel.css` and in ADR 04: flow relative
  properties everywhere (`margin-inline-start`, `padding-inline-*`, `border-inline-*`,
  `inset-*`, `text-align: start/end`, `inline-size`/`block-size` where a box follows the
  text direction). Physical properties only where the meaning is the screen edge: the
  per dock rules (the forced colors page facing borders, around line 633) and the
  collapse chevron's border drawing (`.pdt-toggle__icon`, line 158, rotated by dock).
  Each kept physical rule sits under a `/* physical: <why> */` comment.
- About 13 declarations change (`grep -nE "(margin|padding|border)-(left|right)|text-align:
  (left|right)|[^-](top|left|right|bottom):" assets/css/panel.css`). `.pdt-num` keeps right
  alignment as `text-align: end` (numbers in LTR tables).
- The collapsed side dock turns the header sideways (`writing-mode: vertical-rl`): logical
  properties inside the header now follow it. Check left and right collapsed bars by hand;
  that is the only place where rendering may change.
- `css_rules.test.mjs`: fails on a physical `margin|padding|border-(left|right)`,
  `text-align: left|right` or `left|right` offset outside a rule preceded by a
  `/* physical:` comment.

**E3: dock menu on Popover and anchor positioning** (`lib/phoenix_dev_toolbar/panel_layout.ex`
dock picker, `assets/js/panel.js` dock menu code (lines 86-125, 377-390),
`assets/css/panel.css` `.pdt-dock-menu` rules, `assets/js/test/panel.test.mjs`,
`assets/js/test/support/fake_dom.mjs`, the LiveView test on the picker markup;
`priv/static/panel.js`, `priv/static/panel.css`).

- Markup: `#pdt-dock-menu` gets `popover="auto"` instead of `hidden`; `#pdt-dock` gets
  `popovertarget="pdt-dock-menu"`, keeps `aria-expanded` and `aria-controls` (the browser
  sets the expanded state for popover invokers; keep the attribute for the fake DOM and
  older engines). The picker stays inside its `phx-update="ignore"` wrapper.
- CSS: `#pdt-dock { anchor-name: --pdt-dock }`; the menu `position-anchor: --pdt-dock`,
  `position-area: block-end span-inline-start`, `position-try-fallbacks: flip-inline,
  flip-block`, `margin: 4px 0 0`, plus the `max-height` and scrolling it has today. The
  top layer is not clipped by the header, so the side dock special case goes.
- JS: `placeDockMenu` and the `pdt-dock-menu--start` class go; open, close, Escape and
  outside click come from the popover (light dismiss). Kept: focus to the pressed option on
  open (`toggle` event, `newState === "open"`), focus back to `#pdt-dock` on Escape (the
  browser does this for `popovertarget` invokers: check, keep the code only if needed),
  closing on focus leaving the picker (`focusout`, popovers do not light dismiss on focus),
  closing when the panel collapses (`hidePopover()` in `setOpen`).
- Fake DOM: `showPopover`, `hidePopover`, `togglePopover`, `matches(":popover-open")` and
  a `toggle` event with `newState`; `popovertarget` clicks toggle the target. Existing dock
  menu tests are rewritten against the popover state, not the `hidden` attribute.
- Forced colors: the menu border rule stays; check the menu outline in emulation.
- Verify by hand: all four docks open and collapsed side bars, a narrow side dock (the flip
  fallback), Escape, outside click, Tab out, keyboard focus on open.

**E4: frame animation, measured** (orchestrator, no code unless the trace says so).

- `mix dev`, `/posts`, the Ecto tab with its full list, panel at 420px. Record a Chrome
  performance trace (Chrome DevTools MCP `performance_start_trace`) over five open and
  collapse toggles, bottom dock, then a left dock, with 4x CPU throttling.
- Decision rule: if layout or style recalculation inside the iframe takes more than 4ms
  per frame during the 120ms transition, or any frame is dropped, write a task E5:
  animate `clip-path` (the iframe is set to its larger size at once, the clip animates,
  the smaller size is applied on `transitionend` with a timeout fallback; all four docks;
  `prefers-reduced-motion` skips it; an interrupted toggle settles to the last state).
  Otherwise record the numbers here and close the item as won't do.

## Risks

- **Hot path and production footprint**: none. Panel CSS and panel JS run in the iframe;
  E4 only measures. An E5 would touch the loader, in the host page: then it gets its own
  combined reviewer and host safety checks (never throws, no host layout writes beyond
  the iframe).
- **Host conflicts**: none for E1 to E3 (all inside the iframe). The popover's top layer
  is the panel document's, not the host page's.
- **Browser floor**: raising it is a product decision taken here; README and ADR 04 say it.
  `light-dark()` and anchor positioning both fail soft (colors, menu position), never break
  the toolbar's controls.
- **Fake DOM fidelity**: popover behavior in the fake DOM is ours, not the browser's. The
  hand check in a real browser is the acceptance test for E3; the fake DOM tests guard
  the wiring.
- **Visual regressions**: E1 at the default font size and E2 in horizontal docks must
  render identically. Compare screenshots of `/posts` (bottom dock), `/counter` (LiveView
  tab) and a collapsed left dock before and after (scratchpad, not committed). No media
  retake unless something differs; E3 changes no committed screenshot (the dock menu is
  in none).
- **Tests and ADR sync**: ADR 04 (supported browsers, the CSS convention, the popover
  menu), README (supported browsers), CHANGELOG (three or four lines).
