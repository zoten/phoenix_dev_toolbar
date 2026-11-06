# Architecture Decision Records

One row per ADR, grouped by area. Start here, then open the ADR you need.
How to write and maintain ADRs: see the ADR rules in [AGENTS.md](../AGENTS.md) and
[TEMPLATE.md](./TEMPLATE.md). Status and area come from each ADR's header: keep
this table in sync when you add an ADR or change its status.

Next free number: **10**.

## Product

| ADR | Title | Status |
|---|---|---|
| 00 | [Vision and Scope](./00-vision-and-scope.md) | Accepted |

## Architecture

| ADR | Title | Status |
|---|---|---|
| 01 | [Zero Production Footprint and Installation](./01-zero-prod-footprint-and-installation.md) | Implemented (2026-11-05) |

## Collection

| ADR | Title | Status |
|---|---|---|
| 02 | [Telemetry Collection and Correlation](./02-telemetry-collection-and-correlation.md) | Implemented (2026-11-05) |

## Storage

| ADR | Title | Status |
|---|---|---|
| 03 | [Event Storage: Bounded ETS Ring Buffers](./03-event-storage.md) | Implemented (2026-11-05) |

## UI

| ADR | Title | Status |
|---|---|---|
| 04 | [UI Delivery: Isolated Iframe LiveView and Loader](./04-ui-delivery.md) | Implemented (2026-11-05) |
| 07 | [LiveView Panel: Profiler, Assigns, Event Log, Component Tree](./07-live-view-panel.md) | Implemented (2026-11-05) |
| 08 | [Query Diagnostics: N+1 Detector and EXPLAIN](./08-query-diagnostics.md) | Implemented (2026-11-06) |
| 09 | [Process Panel](./09-process-panel.md) | Implemented (2026-11-06) |

## Plugins

| ADR | Title | Status |
|---|---|---|
| 05 | [Plugin Behaviour](./05-plugin-behaviour.md) | Implemented (2026-11-05) |

## Testing

| ADR | Title | Status |
|---|---|---|
| 06 | [Dev Harness and Testing Strategy](./06-dev-harness-and-testing.md) | Implemented (2026-11-05) |
