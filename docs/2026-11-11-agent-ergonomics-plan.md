# Agent ergonomics from a 0.0.4 field test

An agent audited a large LiveView host app over MCP through six user journeys.
The tools worked; seven frictions cost extra calls or hand-written scripts. This
batch removes them. MCP stays read-only, the "this machine" rules and the
`stack_args` defaults are unchanged.

## Items

1. **Callbacks on N+1 groups and queries** (ADR 08, 13, 15). `NPlusOne` keeps each
   group's last 10 spans (sid, span, count). `Report` names them as `ran_in`
   (view, callback, event, seq, count) and gives each query `callback` and `event`
   (`:request` outside a LiveView callback, `:handle_info`/`:async` for unowned
   LiveView spans). Markdown shows both.
2. **Caller** (ADR 08, 13). `QueryFrames.caller/2`, read time only: the first stored
   frame of a `*Web`/`*Live`/`*Controller` module or of a LiveView callback by
   name and arity, else the frame after the origin. Ecto plugin option
   `caller_modules:`. N+1 groups list distinct `callers` with counts (top 5).
3. **Framework noise** (ADR 08). `QueryFrames.noise/1`: `check_repo_status` (SQL on
   `schema_migrations` or a `Phoenix.Ecto.CheckRepoStatus` frame), `framework` (no
   frame outside the framework). Kept everywhere, dimmed in the tab, left out of
   the Ecto badge and `summary.queries` (counted in `queries.noise`).
4. **Tool list after an upgrade** (ADR 15). No SSE stream, so no
   `tools/list_changed`; `serverInfo.version` is the release (tested). Reconnect
   advice in README, agent setup guide, usage rules and the skill.
5. **Argument errors** (ADR 15). Name the argument, what it takes, the JSON type
   received and where to get a valid value; unknown arguments list the accepted ones.
6. **Inferred callbacks** (ADR 13, 15). `duration_us` stays null; stated in the
   type docs, the tool description and the usage rules; `sort: "slowest"` puts it last.
7. **Panel logging** (ADR 04). `use Phoenix.LiveView, log: false` on `PanelLive`.

## Risks

- **Hot path**: nothing new runs in telemetry handlers. Caller and noise are
  computed at read time (`Report`, the panel process); the panel's badge fold
  classifies each query with string checks over at most 10 frames.
- **Memory**: each N+1 group adds at most 10 small span entries (50 groups max);
  `callers` is capped at 5 per group.
- **Atoms**: frames are parsed as strings, never converted to modules.
- **Host conflicts**: one CSS rule inside the panel iframe; `log: false` only
  touches the toolbar's own LiveView.
- **Public API**: new keys only (`caller`, `callback`, `event`, `noise`,
  `ran_in`, `callers`, `queries.noise`). Summary query counts now exclude
  noise: a visible change for apps with `Phoenix.Ecto.CheckRepoStatus`,
  noted in the CHANGELOG.
- **False positives**: a host query on `schema_migrations` is tagged noise; a
  context function named like a LiveView callback with the same arity in a
  non-web module can be picked as caller. `caller_modules:` narrows the module
  rule; the callback rule stays.
