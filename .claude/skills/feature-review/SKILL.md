---
name: feature-review
description: Use when asked to review a feature implemented across a range of commits in phoenix_dev_toolbar, e.g. "review the assigns inspector since commit abc123" or "code review this phase end to end" - covers Elixir code quality, production footprint, safety of code running in host processes, bounded memory, host isolation, test coverage, ADR sync, and developer-facing UX.
---

# Feature Review

## Overview

Staff-level, product-oriented review of a feature's implementation across a commit range in this library: a dev-only debug toolbar that runs inside other people's Phoenix apps. Combines a technical pass and a product pass, then produces a prioritized, actionable findings list.

The rules being enforced live in `AGENTS.md` ("Library guidelines") and the ADRs under `adr/`: read them first, they are the checklist's source of truth.

## Inputs

Resolve before starting, asking the user if either is missing or ambiguous:
- **commit**: the base commit/tag the feature started from (diff target is `{{commit}}..HEAD` unless the user gives a different range)
- **feature**: short description of what the feature is, for framing the review

## Technical Review Checklist

- **Code quality**: sound, idiomatic Elixir following `AGENTS.md` (pattern matching over `if`, `@spec`/`@doc` on public functions, internal modules `@moduledoc false`, nothing newer than the minimum supported Elixir, e.g. no `Enum.sum_by/2` while 1.17 is supported)
- **Separation of concerns**: logic in small, pure, independently testable modules (like `Page`, `Summary`, `Truncate`); plugs, telemetry handlers and LiveViews stay thin glue
- **Production footprint** (ADR 01): the only host-facing entry point is `PhoenixDevToolbar.Plug` inside the endpoint's `if code_reloading?`; nothing may require host code outside that block (no router macro, no `import`: both `if` branches are expanded at compile time and the `only: :dev` dependency is absent in prod). Every entry point honours `PhoenixDevToolbar.enabled?/0`. `fixtures/host_app` must still compile in `MIX_ENV=prod` and `dev`
- **Host-process safety** (ADR 02): code in telemetry handlers, the plug and `before_send` runs inside the host's processes. Flag anything that can raise (including throws and exits), block (synchronous GenServer calls), do I/O, or do work that grows with input on the untracked fast path. Check behaviour while the Store restarts (its ETS tables vanish)
- **Bounded memory** (ADR 03): every buffer has a cap and a TTL; every payload is truncated before storage (`Truncate`), including `inspect/1` of plug options, exception banners, thrown and exited reasons; no atoms from runtime input; panel assigns and streams are bounded; Registry subscriptions are released
- **Host isolation and security** (ADR 04): no CSS or JS leaks into the host page; `postMessage` checks origin and source on both sides; HEEx escaping (nothing raw); asset URLs never derived from the request path; CSRF handled against the host's session; the sid is a bearer capability and must never be listable
- **Version compatibility**: LiveView internals only through `LiveViewCompat` and covered by the CI matrix (minimum and latest LiveView); JS clients must match the host's server versions. Verify claims about dependency behaviour in `deps/` source, never from memory
- **Test coverage**: happy path and edge cases, per Kent Beck's test desiderata. Watch for tests that pass for the wrong reason, and for seams stubbed exactly where a bug could hide: at least one test should drive a real host LiveView through the endpoint (plug, tracker, notify, panel). `Phoenix.LiveViewTest` skips the socket CSRF check and does not run the JS client, so it is not enough on its own
- **Scalability**: work on hot paths is O(1) per event; scans over sessions are bounded by `max_sessions`
- **No regressions**: existing panels and behaviours outside this change's scope remain intact
- **ADRs**: updated and in sync with the technical/architectural changes made, stating the current decision (no change logs inside ADRs); CHANGELOG has a short line per change

## Product Review Checklist

The users are developers looking at their own app in the browser.

- The feature helps answer "what happened on the page I am looking at, right now" (ADR 00)
- No "black holes", logic loops, or contradictions with existing features: e.g. data that silently disappears or under-reports (dropped events, expired sessions, live navigation), states the user cannot get out of
- The toolbar never gets in the way of the host app (overlap, focus, layout, console noise)
- Information is readable at a glance in the collapsed bar and discoverable in the panel (no key data hidden in tooltips only), with clear empty and error states
- UI follows `assets/css/panel.css` tokens and existing `pdt-` components, in light and dark mode, keyboard accessible; new components are added to the panel stylesheet, not inline
- The change is checked by hand in a real browser with `mix dev`, not only through tests
- ADRs are updated and in sync with the product-facing changes

## Process

1. Confirm `commit` and `feature`, and the diff range to review.
2. Read `AGENTS.md`, the related ADRs under `adr/`, the diff, and the relevant tests.
3. Work through both checklists above; note findings with file:line references. Reproduce the important ones (a scratch test in the scratchpad, `mix dev` in a browser) before reporting them.
4. Prioritize findings (blocker / should-fix / nit) and propose a resolution plan, grouping small fixes into batches as `AGENTS.md` describes.
5. Ask clarifying questions for anything ambiguous rather than guessing at intent.
