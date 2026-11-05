# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Project conventions: AGENTS.md, ADRs, roadmap, `mix precommit`, CI matrix (ADR 00, ADR 06)
- `PhoenixDevToolbar.enabled?/0` runtime guard (ADR 01)
- Bounded ETS event store: caps, flood guard, TTL sweep, LiveView DOWN cleanup (ADR 03)
- Payload truncation and key redaction helpers (ADR 03)
- Telemetry collector: plugin fan-out, crash quarantine, `$callers` attribution (ADR 02)
- LiveView session tracking: dead render link, reconnect, live navigation, nested (ADR 02)
- Registry based live notifications for panel subscribers (ADR 03)
- Built-in Request and Ecto collectors, default plugins (ADR 02)
- `PhoenixDevToolbar.Plug`: page tracking, loader injection, asset serving (ADR 04)
- Live panel served by the plug, no router changes: summary, Ecto and Request tabs (ADR 01, ADR 04)
- Loader (shadow DOM iframe, collapse state), panel JS and CSS, esbuild bundles (ADR 04)
- `mix dev` harness: SQLite demo app with N+1, events, Task.async and dead pages (ADR 06)
- Prod compile check of a fixture host app installing the toolbar (ADR 01)
- Panel keeps following a tab after older sessions expire; no missed or out of order events (ADR 04)
- Bounded exception banners and plug options; panel asset URLs from the plug path (ADR 03, ADR 04)
- Toolbar disables itself, with a warning, in releases unless explicitly enabled (ADR 01)
- Panel UX: hide to a corner pill, HTTP/live query tags, timings, dropped badge, ARIA tabs (ADR 04)
