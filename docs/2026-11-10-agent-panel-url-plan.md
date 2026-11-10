# Standalone panel URL and `data-pdt-*` row attributes

Roadmap item: "(S) Documented standalone panel URL plus `data-pdt-*` row
attributes, for browser-driving agents". A browser-driving agent (Playwright,
Chrome DevTools MCP, claude-in-chrome) opens the panel in its own tab and reads
numbers off the DOM, without parsing "1.2ms" strings or guessing the sid.

## Today

- `GET <path>/panel?sid=<sid>` already renders the panel outside the iframe, but:
  - the agent has to find the sid (`script[data-pdt-sid]` on the host page)
  - `panel.js` waits for the loader's `pdt:state`, so the panel stays "closed":
    `visible?` is false, the component tree and process polling never start, and
    the toggle, hide and dock buttons post to a parent that does not exist
- Rows carry ids and CSS classes, values are formatted for humans only.

## Decision (ADR 14)

1. **Panel URL resolution** (`PhoenixDevToolbar.Plug`):
   - `?sid=<sid>`: as today (the loader's iframe).
   - `?path=/posts`: the newest page whose session path is exactly that.
   - no parameter: the newest page.
   - "Page" means the request root: a connected mount resolves to its request
     parent, a live navigated LiveView stays itself (as the iframe shows it).
   - Resolved once per panel load, in the request process, with ETS reads only
     (`Report.latest/1` plus `Store.session/1`). Reload to see a newer page.
2. **Standalone mode** (`panel.js`): `window.parent === window` adds
   `pdt-standalone` to the root, sets the panel open (so polling runs while the
   browser tab is visible) with the bottom dock classes. CSS hides the toggle,
   hide, dock picker and "+N" controls in that mode.
3. **Row attributes**: a documented, stable contract, names mirror the
   `Report` keys (kebab case). Booleans are present only when true.
   - `#pdt-panel`: `data-pdt-root` (root sid), `data-pdt-sids` (comma separated).
   - each tab section: `data-pdt-tab="<plugin id>"` (all tabs are in the DOM).
   - every event row: `data-pdt-row` (`query`, `n-plus-one`, `callback`,
     `render`, `client`, `request`, `profile`), plus `data-pdt-sid`,
     `data-pdt-seq`, `data-pdt-duration-us` where the row is one event.
   - query: `data-pdt-source`, `data-pdt-error`, `data-pdt-n-plus-one`.
   - n-plus-one: `data-pdt-count`, `data-pdt-callbacks`.
   - callback: `data-pdt-callback` (`mount`, `handle_event`, ...),
     `data-pdt-event`, `data-pdt-error`. render: `data-pdt-error`.
     client: `data-pdt-event` (the `phx:*` type).
   - profile: `data-pdt-callback` (the row label), `data-pdt-count`,
     `data-pdt-total-us`, `data-pdt-max-us`.
   - request: `data-pdt-method`, `data-pdt-status`.
4. **Docs**: Plug moduledoc "Standalone panel" section, `usage-rules.md` "In a
   browser" section, one paragraph in the report skill, ADR 04 pointer.

## Tasks

1. Plug resolution + tests (`plug_test.exs`, `panel_live_test.exs` via
   `data-pdt-root`).
2. Row attributes in `components.ex`, `panels/request.ex`,
   `panels/live_view_sections.ex`, `panel_layout.ex` + LiveView tests.
3. `panel.js` standalone + `panel.css` + DOM test (`panel.test.mjs`, unframed).
4. ADR 14, ADR 04 line, docs, CHANGELOG, roadmap; `mix assets.build`,
   `mix precommit`, check in `mix dev` (iframe unchanged, standalone works).

Small and low risk: done inline, no subagents.

## Risks

- **Hot path**: none. Resolution runs only on `GET <path>/panel`, behind the
  host check, untracked; telemetry handlers are untouched.
- **Production footprint**: none, all code sits behind the plug.
- **Memory bounds**: attributes add a few bytes per row; DOM lists are already
  capped by the streams' limits.
- **Host conflicts**: the standalone class only exists in our own document;
  framed behavior is unchanged (`window.parent !== window`).
- **Security**: `?path=` is matched as an exact string (no regex from input,
  no atoms), behind the same host check as `?sid=`. The panel already showed
  any sid to anyone allowed by the host check, so no new exposure.
- **Public API**: the attribute names become a contract like `Report` keys
  (ADR 13): renaming one needs a CHANGELOG line; tests pin them.
- **Tests and ADR sync**: plug resolution, attributes per row kind, standalone
  JS; ADR 14 new, ADR 04 and ADR 13 cross links.
