# BEAM tools plan: process inspector, System tab, actions, cluster

## Context

The Process tab (ADR 09) reads only the page's LiveView and its sids, and its one
action is "GC now". The goal is to grow it into BEAM debugging tooling: inspect any
process, navigate between them, see trees, act on processes (kill, suspend, ...),
and later a cluster/eval plugin. Decisions taken with the user:

- Node-wide views go in a **new built-in "System" tab**; Process stays page-centric.
  Both share one inspector component; pid links jump between them.
- Destructive actions are **guarded**: confirm step, protected set, suspend auto-resumes.
- Eval is an **opt-in plugin, read-only and loopback-only by default, overridable**,
  with security notes in its ADR, the plugin guide and SECURITY.md.

## What changes vs. the original wish list

- **Add**: process "top" (find the leaking/busy process: the real reason people open
  observer), `current_stacktrace`, `:sys.get_state`/`get_status` for OTP processes,
  "watch" (monitor a pid, show exit reason), "kill this LiveView" with chosen reason
  (tests reconnect and form recovery: the most LiveView-specific win), message queue
  peek only below a size threshold.
- **Drop**: link/unlink (linking two host processes, or the panel to one, only creates
  cascading crashes; no debugging value), "send arbitrary message" (needs term parsing:
  that is eval, belongs in the eval plugin), forced hibernate (not possible externally).
- **Merge**: the roadmap's "opt-in `handle_info` tracing via `:erlang.trace/3`" becomes
  the inspector's message trace (one tracer design, not two).
- **Plan better**: there is no cross-tab navigation API today (`panel_live.ex:59` only
  handles a clicked tab) and no loopback check anywhere. Both are prerequisites.

## Phases (each its own dated plan doc + ADR, in this order)

### Phase 5a: Foundation (ADR 10 "Process addressing and actions policy")
- `PidRef` parsing: `"<0.123.0>"` via `:erlang.list_to_pid/1` (no atoms), registered
  names matched against `Process.registered/0` strings (never `String.to_atom`),
  local node only. Browser never sends raw pids for page targets (keep ADR 09 index rule);
  System tab sends the string, server re-validates.
- Protected set (refused for kill/suspend, allowed for read/GC): toolbar's own
  processes (already tagged in ADR 09), the panel's own pid and socket transport,
  `init`, `code_server`, `application_controller`, `logger`, `erts_*`, kernel/stdlib
  supervisors, the host endpoint's supervisor. One module, unit tested.
- Cross-tab navigation: `Panel.navigate(socket, plugin_id, params)` public helper,
  plus a bounded breadcrumb stack (20) per panel, kept in the panel LiveView.
- Shared `ProcessInspector` function component (moved out of `panels/process.ex`).

### Phase 5b: Inspector for any pid (extends ADR 09, System tab skeleton ADR 11)
- System tab with a pid/name search box; inspector shows ADR 09 data plus
  `current_stacktrace`, `$ancestors`/`:parent`, and for OTP processes `:sys.get_state`
  with a timeout (in `start_async`, truncated with `Truncate`, redaction applied).
- Every pid rendered anywhere (Process tab relations, Ecto/LiveView events) is a link.

### Phase 5c: Actions (ADR 10)
- Kill: the page's LiveView (reasons: `:kill`, `:shutdown`, `{:shutdown, :debug}`,
  a raise) and any non-protected pid. Confirm step, rate limited, logged via `Logger`.
- Suspend/resume with TTL (default 10s, max 60s): auto-resume from a supervised
  toolbar process that monitors the panel, so a closed panel never leaves a frozen
  process. Never suspend while a `:sys` call is in flight.
- Watch: panel monitors a pid, shows exit reason and time. Bounded (10 watches).
- Message peek: first N messages only when `message_queue_len` < threshold (e.g. 100).

### Phase 5d: Trees (ADR 11)
- Backwards: ancestors chain (`$ancestors`, `:parent`, OTP 25+), cheap, in the inspector.
- Forwards: supervision subtree, lazy expand. `count_children` first; above a cap
  (e.g. 200) show counts and a paged list, never `which_children` on huge
  DynamicSupervisors. Calls run in `start_async` with timeout (a busy supervisor never
  blocks the panel).
- Full tree: applications (`Application.started_applications/0` -> application master
  -> top supervisor), host apps first, OTP apps collapsed.

### Phase 5e: Process top (ADR 11)
- Top 50 by memory / reductions delta / queue length, sampled on demand or every N
  seconds only while shown. Cost guard: `Process.list` size cap with a warning
  (100k processes: one sweep in a Task, bounded).

### Phase 5f: Message trace (replaces roadmap's `handle_info` tracing)
- Opt-in, one traced pid at a time, `:erlang.trace/3` with a session tracer (OTP 27
  trace sessions when available, so we never steal the global tracer from recon/dbg),
  rate limited, auto-stop after N messages or T seconds, payloads truncated.

### Phase 6: Cluster and eval (separate opt-in plugins, ADR 12)
- `Plugins.Cluster`: `Node.list/0`, connection state, per-node memory/process count
  via `:erpc` with timeouts. Remote pids become inspectable read-only through `:erpc`.
- `Plugins.Eval`: opt-in, not in `:defaults`. Defaults: `allow: :read_only`
  (a curated set of read calls, no free eval) and `clients: :loopback`
  (`conn.remote_ip`/socket peer check, plus a per-boot token). Overrides:
  `allow: :eval`, `clients: :any` each log a loud boot warning. Evaluated code runs in
  a supervised Task with timeout, output truncated. Security notes in ADR 12, the
  plugin guide and SECURITY.md.

## Risks (review left)
- **Hot path**: none of this attaches telemetry; tracing is the only path that adds
  host overhead, hence opt-in, single pid, auto-stop.
- **Production footprint**: all new plugins behind `enabled?/0`; eval module must not
  be reachable unless configured. Extend `fixtures/host_app` prod compile check.
- **Host crash / node freeze**: protected set, suspend TTL with supervised resume,
  `:sys` calls and supervisor calls only with timeouts in `start_async`.
- **Memory bounds**: caps on top list, tree children, breadcrumbs, watches, trace
  messages, message peek; `:sys.get_state` output truncated.
- **Atoms**: no atom creation from input (pid parse and name lookup by string match).
- **Security**: kill/suspend of any pid is a DoS primitive over HTTP: same loopback
  consideration as eval; decide in ADR 10 whether actions also default to loopback.
- **Public API**: `Panel.navigate/3` is new public API (doc, spec, CHANGELOG line).
- **Tests**: protected-set unit tests; inspector tests against spawned GenServers and
  a test supervision tree (`start_supervised!`); suspend TTL test via monitor, no sleep.

## Verification
- Docs-only step: `mix docs --warnings-as-errors` and link check of new ADR rows.
- Per phase later: `mix test` on affected files, `mix dev` (or `PORT=4001`) to check
  the System tab, pid links, kill-LiveView recovery and suspend auto-resume in a real
  browser, then `mix precommit` with all checkpoints green.
