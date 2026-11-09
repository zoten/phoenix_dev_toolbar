# Ecto export and docks: review fixes

Follow up of the feature review of `fadec0b..cd7b5d1` (Ecto JSON export, toolbar docks).

## Batch A: Copy never hangs

- A Copy refused because an EXPLAIN is running, or an export that crashes, answers the
  hook with `pdt:export` `%{error: ..., page: ...}`: the pending clipboard write is
  settled at once with that message. Copy is disabled while an EXPLAIN runs.
- The `export_error` assign goes: the hook's result line shows every outcome.
- A page change settles a pending copy, not only a held one.
- The Copy state machine moves to `assets/js/export_copy.mjs` (clipboard, timers and
  DOM injected) with `node --test` coverage; the hook is glue.

## Batch B: page space opt out (ADR 04)

- `config :phoenix_dev_toolbar, reserve_space: false` turns the default off: the plug
  adds `data-pdt-reserve="false"` to the loader tag.
- The dock menu gets a "Reserve page space" toggle (`#pdt-reserve`, `aria-pressed`).
  The choice is stored in `pdt:layout` (`reserve`) and overrides the config.
- Not reserving: no flow height, no `<html>` padding; the bar overlaps the page as
  before the docks.

## Batch C: nits

- `EctoExport.request/1`: `root` must be one of `sids` (400 otherwise).
- The Download link carries `explain=true` only for the full format.
- The loader stops toggling the unused `.frame.open` class.

Deferred: EXPLAIN buttons stay clickable during a Copy (streamed rows would need a
restream); `placeHost` only on dock change.

## Risks

- Hot path: none, the plug reads one app env key per injected HTML response.
- Production footprint: unchanged, no new entry point.
- Memory: the hook holds at most one export for 60 s, as before.
- Host conflicts: the opt out removes the only host element write when chosen.
- Public API: a new `reserve_space` config key, documented in the README and ADR 04.
- Tests: ExUnit for busy and failure pushes, the loader attribute and `root` check;
  node tests for `export_copy.mjs` and the layout `reserve` field.
