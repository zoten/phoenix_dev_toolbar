# ADR 14: Standalone Panel and Row Attributes

**Status:** Implemented (2026-11-10)  
**Area:** integration  
**Related:** [ADR 04](./04-ui-delivery.md) (the panel route, the iframe and `panel.js`), [ADR 13](./13-report-read-api.md) (the same data for agents that evaluate code, and the key names mirrored here)

## Context

Coding agents that drive a browser (Playwright, Chrome DevTools MCP, browser
extensions) can open the panel, but it was built for the loader's iframe only:
the agent had to dig the sid out of the toolbar's script tag, the panel waited
for the loader's state (so it stayed "closed" and its polling never started),
and every number on screen was formatted for humans ("1.2 ms", "24 rows").

## Decision

**Panel URL.** `GET <path>/panel` resolves the page to show from its query string:

- `?sid=<sid>`: that page (what the loader's iframe uses).
- `?path=/posts`: the newest page whose session path is exactly that string.
- nothing: the newest page.

A page is what the iframe shows: a connected mount resolves to its request
parent, a live navigated LiveView (its parent is a LiveView) is its own page.
The plug resolves it once per panel load, in the request process, with ETS
reads only (`Report.latest/1`, `Store.session/1`), behind the same host check
as the panel itself. `?path=` is compared as a string: no regex, no atom.
Reloading the panel picks a newer page.

`?path=` and the newest page find a page without its sid, so they answer only
the clients MCP accepts (ADR 15 `clients:`; `mcp: false` counts as the default):
this machine unless listed, never through a proxy unless `clients: :any`. Any
other client gets the panel with no page and a hint to open it from the page's
toolbar, whose iframe carries the sid. `?sid=` answers any client the host check
lets in, as the iframe always did (phones on the LAN). The empty state says what
was asked: an expired sid, no capture at that path, nothing captured yet, or a
client that may not look pages up.

**Standalone mode.** When `panel.js` runs as a top level page
(`window.parent === window`) it adds `pdt-standalone` to its root, docks at the
bottom and sets itself open, so the panel reports itself visible and its
polling (component tree, process inspector) runs. CSS hides the controls that
only talk to a loader: toggle, hide, dock picker, the "+N" badge. Framed, the
panel is unchanged.

**Row attributes.** The panel carries `data-pdt-*` attributes with raw values,
named after the `Report` keys in kebab case. Booleans are present only when
true, missing values are omitted.

| Element | Attributes |
|---|---|
| `#pdt-panel` | `data-pdt-root` (root sid), `data-pdt-sids` (the page's sids, comma separated) |
| tab section | `data-pdt-tab` (plugin id); every tab is in the DOM, hidden ones too |
| every event row | `data-pdt-row`, `data-pdt-sid`, `data-pdt-seq`, `data-pdt-duration-us` |
| `query` | `data-pdt-source`, `data-pdt-error`, `data-pdt-n-plus-one` |
| `n-plus-one` (no sid, seq, duration) | `data-pdt-count`, `data-pdt-callbacks` |
| `callback` | `data-pdt-callback` (`mount`, `handle_event`, ...), `data-pdt-event`, `data-pdt-error` |
| `render` | `data-pdt-error` |
| `client` | `data-pdt-event` (the `phx:*` type) |
| `request` | `data-pdt-kind` (`response`, `dispatch`, `exception`), `data-pdt-method`, `data-pdt-status`, `data-pdt-error` |
| `profile` (no sid, seq, duration) | `data-pdt-callback` (the row label), `data-pdt-count`, `data-pdt-total-us`, `data-pdt-max-us` |
| `#pdt-empty` | `data-pdt-lookup`: `sid`, `path`, `newest` or `gated` (why there is no page) |

The names are a contract, like `Report`'s keys: adding one is not a breaking
change, renaming or removing one is (a CHANGELOG line). Tests pin them.
Summary badges keep their stable ids (`#pdt-badge-<id>`).

## Consequences

- A browser-driving agent loads the host page, opens `<path>/panel?path=/posts`
  and reads numbers with `querySelectorAll('[data-pdt-row="query"]')`, without
  parsing formatted text or knowing a sid.
- The MCP tools (ADR 15) pick pages with the same resolution
  (`PhoenixDevToolbar.PageLookup`) and return the standalone `panel_url`.
- A developer can open the panel in its own tab, next to the page, for a large
  view of one page.
- The panel's markup gains a small public surface: a refactor of a row must keep
  its attributes.

## Open limits

- Process, System, Cluster, Eval and third-party plugin tabs have ids but no
  `data-pdt-*` attributes.
- Rows are bounded by the tabs' DOM caps: the full lists are in `Report`.
- The standalone panel follows live navigation of its page, but a new page load
  in the host's tab is another page: reload the panel to see it.
- `?path=` matches the path a page started at: a live patch keeps its LiveView's
  mount path, and `/posts/` is not `/posts`.
