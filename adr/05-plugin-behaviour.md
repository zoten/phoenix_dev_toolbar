# ADR 05: Plugin Behaviour

**Status:** Implemented (2026-11-05)  
**Area:** plugins  
**Related:** [ADR 02](./02-telemetry-collection-and-correlation.md) (collection rules), [ADR 03](./03-event-storage.md) (storage, caps), [ADR 04](./04-ui-delivery.md) (panel), [ADR 07](./07-live-view-panel.md) (the LiveView tab)

## Context

The community will want panels for Oban, Ash, auth state, Absinthe and more. If
built-ins use private paths, the plugin API rots. A plugin runs code in three
places: inside host processes (its collector), and in the panel LiveView (its
summary and its tab). The contract must make the cheap path obvious and keep a
broken plugin from breaking the host or the rest of the toolbar.

## Decision

Every panel, built-ins included (`PhoenixDevToolbar.Plugins.Ecto`, `.Request`,
`.LiveView`), implements the public `PhoenixDevToolbar.Plugin` behaviour, and its
tab is a `PhoenixDevToolbar.Panel` LiveComponent. Guide: `guides/writing-a-plugin.md`;
example: `examples/oban` (the jobs a page enqueued).

**Plugin callbacks** (`use PhoenixDevToolbar.Plugin, id: :jobs, name: "Jobs"` defines
`id/0`, `name/0` and a default `init/1`, and checks at compile time that the id is an
atom other than the reserved `:client` and the name a string):

| Callback | Runs in | Purpose |
|---|---|---|
| `init(opts)` (optional) | the toolbar, at attach | `{:ok, config}` or `{:error, reason}` |
| `telemetry_events(config)` | the toolbar, at attach | event names to attach |
| `collect(event, {measurements, metadata}, %Context{})` | the host process | `{:record, Event.t()}` or `:skip` |
| `summary_init/1`, `summary_add/2`, `badges/1` (optional, all or none) | the panel | badges folded event by event |
| `panel/0` (optional) | the panel | the tab's `Panel` module |

- **Registration**: `config :phoenix_dev_toolbar, plugins: [:defaults, {Mod, opts},
  {:exclude, Mod}]` (`PhoenixDevToolbar.Config`). `:defaults` expands in place to Ecto,
  Request, LiveView, Process (ADR 09), System (ADR 11); a module listed twice keeps its first position and its last
  options (so a built-in listed with options overrides it); `{:exclude, Mod}` removes
  it. Validation never raises during the host's boot: an entry that is not a module or
  `{module, opts}`, a module that is missing, does not implement the callbacks, defines
  only part of the summary trio, has a `panel/0` that is not a `Panel`, has an id that
  is not an atom (or is `nil` or a boolean), is reserved or taken, a name that is not a
  string, or whose `id/0` or `name/0` raises, throws or exits, is logged and skipped.
  The Ecto plugin takes `repos:`, falling back to the top level `repos` config, and
  `n_plus_one:` (the N+1 detector's threshold, ADR 08).
- **Attach** (`PhoenixDevToolbar.Collector.attach/1`): runs each plugin's `init/1` and
  `telemetry_events/1`; a plugin whose `init/1` returns an error, raises, or whose
  events are not non empty lists of atoms is logged and left out (`:telemetry.attach/4`
  would otherwise raise in the host's application start). Event names a plugin lists
  twice are attached once. The handler config holds module names only: `:telemetry`
  copies it into every emitting process, tracked or not. Configs live in
  persistent_term and are read (no copy) once the process is known to be tracked, then
  handed over in `Context.config`. A recorded event is stamped with the plugin's own id,
  whatever `Event.new/4` was given: a plugin cannot fill another one's tab, cap or summary. `Collector.plugins/0` lists the attached plugins
  with their config, in configuration order, for the panel.
- **Context**: `sid`, `source` (`:self` or `:caller` for `$callers` children), `config`.
  **Event**: `plugin` (the plugin id), `kind`, `at`, `duration` (microseconds, from
  native units in `Event.new/4`), `data` (already bounded with
  `PhoenixDevToolbar.Truncate`, stored as is), `sid` and `seq` set on insert.
- **Panel** (`use PhoenixDevToolbar.Panel`, a `Phoenix.LiveComponent`): the toolbar
  defines `update/2` (a panel defining `update/2` or `update_many/1` fails to compile) and delivers the
  plugin's events through `handle_reset(events, socket)` (a new page: every stored
  event; also once with `[]` before the first render) and `handle_events(events,
  socket)` (new events, oldest first), with `send_update` after the panel's own
  callback, so deliveries keep their order. Props: `@config`, `@page`, `@shown?` (tab
  selected), `@visible?` (panel open and browser tab visible); `handle_props/1` runs
  only when one of them changed (LiveView calls `update/2` on every parent render).
  `send_after/4` schedules a message for `handle_info/2` (`send_update_after`).
  Deliveries happen only once connected: the dead render shows empty tabs. Plugins
  style with the panel's `pdt-` classes; `Panel.duration/1` formats durations.
- **Shell** (`PhoenixDevToolbar.Shell`, pure): tabs in configuration order (plugins
  with `panel/0`), events routed to their plugin's tab by id, summaries folded per
  plugin. Badges are computed when a summary changes, never at render, and validated
  (`id` and `text` strings, `level` in `:ok | :info | :warn | :error`, `title` nil or a
  string); the DOM id is `pdt-badge-<id>`, global to the panel, so ids start with the
  plugin id. Each tab notes how many of its plugin's events were trimmed (ADR 03).
- **Quarantine**, where the plugin's code runs:
  - collector (host process): a `collect/3` that raises, throws, exits or returns
    anything else is skipped for the node: a bounded banner (`Truncate.banner/2`, which
    survives a `message/1` that itself fails) is stored in persistent_term, the full
    error logged once, and the page notified so its panel shows it at once;
  - summary (panel): `summary_init/1`, `summary_add/2` or `badges/1` raising marks the
    plugin broken for that panel; its summary and badges are dropped;
  - tab (panel): `mount/1`, the update path, `handle_event/3`, `handle_async/3` and all
    of `render/1` (the code before `~H` too) run behind a boundary; the template is evaluated once there through
    `Phoenix.HTML.Safe` (render only builds a `%Rendered{}`, evaluated later while
    LiveView diffs, outside any boundary). An error breaks that tab only.

  The tab shows "disabled after an error" with the banner and a Re-enable button
  (`Collector.release/1`, the panel's errors forgotten, the page reloaded into every
  tab); a disabled plugin without a tab shows an error badge that re-enables it.

## Consequences

- Built-ins are the reference implementation and the API's test suite; a test plugin
  with a tab (`test/support/tabbed_plugin.ex`) and the Oban example drive the public API
  end to end through a real host LiveView.
- `PanelLive` is generic glue (page, subscriptions, flush, delivery); its markup is in
  `PanelLayout`, its reads in `PageData`.
- Plugin markup renders inside our iframe only, so it cannot break the host page.
- A panel's template renders twice per update (the check, then LiveView's diff):
  acceptable for a dev tool's small templates.

## Open limits

- Re-enabling a plugin whose summary or template fails on the page's stored events
  breaks it again until the page changes.
- A template that nests live components cannot be converted to HTML: it is not checked,
  and a raise in it still crashes the panel.
- Callbacks returning the wrong shape (`{:ok, socket}` from `handle_event/3`) or a
  `phx-target={@myself}` without `handle_event/3` fail inside LiveView, outside the
  boundary.
- A plugin that blocks in `collect/3` (a synchronous call) cannot be stopped from
  inside the host process: documented, not enforced.
- Concurrent first errors of one plugin in many processes can each log and write the
  banner once (a get then put, not atomic).
- After a summary error the tab shows the error above the plugin's still working
  component.
- No plugin stylesheets, no pull data source other than the panel component itself
  (`start_async/3` covers it).
- Excluding `Plugins.LiveView` removes the LiveView tab, and the loader's client events
  then have nowhere to go: they are dropped.
- The behaviour is unstable until 1.0: changes go in the CHANGELOG.
