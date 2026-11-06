# Ecto tab: JSON export of captured queries

## Context

The Ecto tab shows a page's queries but nothing leaves the panel: to share them (an issue, a
chat with an LLM, a diff between two runs) the developer copies rows by hand. Add an export
in two formats, delivered as a file download or copied to the clipboard:

- **Short**: per query `sql`, `params`, `location` (first stacktrace frame outside Ecto)
- **Full**: everything captured (tags, details, timings, stacktrace) plus, when asked,
  EXPLAIN plans run at export time

Decisions taken with the user: EXPLAIN runs at export time (bounded), delivery is both
Download and Copy.

## Approach

### Data: one pure module, `PhoenixDevToolbar.EctoExport` (`@moduledoc false`, new file)

`build(events, format, opts) :: map()` turns the page's Ecto events into a JSON-ready map
(strings, numbers, booleans, nil, lists, maps with string keys only: no tuples, no atoms
as values). It does not encode JSON: Jason is dev/test only here and `JSON` needs
Elixir 1.18 (we support 1.17). The map travels through `push_event/3`, which Phoenix
encodes with the host's own JSON library, and the browser does
`JSON.stringify(payload, null, 2)`.

- Envelope: `%{"format" => "short" | "full", "exported_at" => iso8601, "path" => page path,
  "count" => n, "queries" => [...]}`, oldest first.
- Short row: `seq`, `sql`, `params` (the stored, redacted, inspected string: never the raw
  `data.explain` params), `location` (first stacktrace frame or nil).
- Full row: short fields plus `at` (iso8601), `duration_us`, `phase` ("http" when
  `sid == page.root`, else "live"), `repo` (`inspect/1`), `source`, `result`
  (`%{"ok" => rows}` / `%{"error" => message}`), `times` (string keys, µs), `caller`
  (task), `n_plus_one` (bool), `stacktrace`, and `explain`:
  `%{"status" => "ok", "plan" => text}` | `"error"` + `reason` | `"not_explainable"` +
  `reason` | `"skipped"` (budget hit) | `"not_requested"`.
- N+1 tags: fold the events through `NPlusOne.new(threshold)` / `NPlusOne.add/2`
  exactly like `Panels.Ecto.detect/2` (`lib/phoenix_dev_toolbar/panels/ecto.ex:67`), so a
  Clear marker in the Store is honoured the same way.
- EXPLAIN: `explain_all(events, repos, budget)` runs `Explain.run/2`
  (`lib/phoenix_dev_toolbar/explain.ex:77`) sequentially for explainable events, at most
  **50 queries** and a **15 s** total wall clock (checked before each run; each run keeps
  its own 5 s timeout). The rest become `"skipped"`. Returns `%{seq => result}`.
- Move `explainable?/1` and `explain_reason/1` from `Components`
  (`lib/phoenix_dev_toolbar/components.ex:167-190`) to `Explain` (`@doc false` public) so
  the row and the export share them; `Components` calls them.

### Panel: `Panels.Ecto` (`lib/phoenix_dev_toolbar/panels/ecto.ex`)

- Toolbar above the list: a `<form id="pdt-ecto-export" phx-submit="export">` with
  format radios (short / full, default short), an "include EXPLAIN" checkbox (only
  meaningful for full), and two submit buttons `name="action"` `value="download" | "copy"`
  (`#pdt-export-download`, `#pdt-export-copy`). Disabled with `aria-busy` while an export
  runs; hidden when the page has no queries (an assign `queries?`).
- `handle_event("export", params)`: validate format/action against fixed strings (no
  atoms from input), read events from the Store for `page.sids` (`Store.events/1`,
  filter `plugin: :ecto`), then `start_async(:export, fn -> EctoExport.build(...) end)`.
  Runs in a task, so EXPLAINs never block the component; one export at a time
  (`exporting` assign), `cancel_async(:export)` in `handle_reset/2` next to
  `cancel_explain/1`, so a page change frees the pool connection.
- `handle_async(:export, {:ok, payload})`: `push_event(socket, "pdt:export",
  %{action: action, filename: "ecto-queries-#{format}-#{ts}.json", payload: payload})`.
  On `{:exit, reason}`: a short error line in the form.
- push_event from a LiveComponent reaches hooks of the whole LiveView: the hook filters
  on its own event name only, and the component is the only sender.

### JS: `PdtExport` hook (`assets/js/panel.js`, registered next to `PdtPanel`)

On `#pdt-ecto-export` (form, not `phx-update="ignore"`: the server owns it).
`this.handleEvent("pdt:export", ...)`:
- download: `Blob([JSON.stringify(payload, null, 2)], {type: "application/json"})`,
  `URL.createObjectURL`, temporary `<a download>` click, revoke URL
- copy: `navigator.clipboard.writeText(...)`, feature detected; on rejection (no
  permission, lost user activation after a long EXPLAIN run) show "Copy failed: use
  Download" in a status span (`#pdt-export-status`, `aria-live="polite"`), "Copied" on
  success
- Then `mix assets.build`, commit `priv/static`.

### Docs

- ADR 08: new "Export" bullet block (formats, fields, EXPLAIN budget, delivery, never the
  raw explain params) and limits (copy may fail after a long EXPLAIN run; 500 queries per
  session cap applies).
- CHANGELOG: one line, "Ecto tab JSON export (short / full with EXPLAIN), download or copy (ADR 08)".
- Plan file `docs/2026-11-06-ecto-export-plan.md` with this content and the Risks below.

## Risks

- **Hot path**: none: nothing changes in `collect/3`; all work is in the panel on click.
- **Production footprint**: none new: lives in the panel, which only exists when enabled.
- **Memory bounds**: payload built from the Store (500 queries per plugin and session,
  SQL 8 KB, params truncated): a few MB at most, built in a task, sent once, not kept in
  assigns. EXPLAIN bounded to 50 runs / 15 s.
- **DB load**: export EXPLAINs reuse `Explain.run/2` (rolled back transaction, 5 s
  timeout, never ANALYZE); sequential, one export per panel, cancelled on page change.
  Single EXPLAIN and export share the pool: keep them mutually exclusive (button disabled
  while either runs).
- **Leaking secrets**: export uses the redacted `params` string only; raw `data.explain`
  params are never serialised (test asserts it). Plans/DB errors may quote values, as in
  the tab today (existing ADR 08 limit).
- **Host isolation**: hook lives in the panel iframe bundle; no host JS/CSS touched.
  Clipboard in a same-origin iframe is allowed by default policy; feature detected.
- **Public API**: none (internal modules).

## Tests (written first)

- `test/phoenix_dev_toolbar/ecto_export_test.exs` (async, pure): short and full shapes
  from built `Event`s; JSON-safe values only (walk the map: no tuples/atoms/pids);
  raw explain params absent; N+1 flag set from threshold and reset by a Clear event;
  `explain: false` gives `"not_requested"`; non explainable rows carry the reason;
  budget of 1 marks the second explainable query `"skipped"`.
- `test/phoenix_dev_toolbar/ecto_export_panel_test.exs`: LiveView workflow on the SQLite
  demo repo (reuse helpers from `explain_panel_test.exs` and `test/support`): run queries,
  submit `#pdt-ecto-export` with short/download, `assert_push_event` with the payload;
  full + EXPLAIN gives `"status" => "ok"` plans; unknown format/action ignored.
- Existing `explain_panel_test.exs`, `n_plus_one_panel_test.exs` still pass after moving
  the helpers.

## Verification

1. `mix test test/phoenix_dev_toolbar/ecto_export_test.exs test/phoenix_dev_toolbar/ecto_export_panel_test.exs test/phoenix_dev_toolbar/explain_panel_test.exs`
2. `mix assets.build`
3. `PORT=4001 mix dev`, open a page with queries, Ecto tab: Download short and full (with
   EXPLAIN), open the files; Copy and paste; check a long EXPLAIN run's copy fallback
   message; check keyboard focus and the busy state (Chrome DevTools MCP).
4. `mix precommit` with all checkpoints green.
