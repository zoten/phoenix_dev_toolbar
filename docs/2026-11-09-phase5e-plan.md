# Phase 5e plan: process top

Part of [the BEAM tools plan](./2026-11-09-beam-tools-roadmap-plan.md), ADR 11.
The question it answers: which process is leaking, busy or backed up, right now.

## Scope

- A "Top processes" section in the System tab's start view (with the
  applications): the 50 processes with the most memory, the most reductions in
  the last half second, or the longest message queue, picked in a select. Read on
  the "Read" click, never polled. Each row: pid (a link), name, memory, queue,
  reductions per second; toolbar processes tagged.
- Above 100 000 processes nothing is read: the panel says how many there are.

## Task 1: `ProcessTop` (moderate risk: a read of every process, combined review)

`lib/phoenix_dev_toolbar/process_top.ex` (`@moduledoc false`):

- `top(by, opts)`, `by` in `:memory | :reductions | :queue` (the client sends a
  string, matched): `Process.list/0`, refused above `max_processes` (100 000).
  One sweep of `Process.info(pid, [:memory, :message_queue_len, :reductions])`;
  for `:reductions` a second sweep `interval_ms` (500) later, the delta per
  second. Only the 50 first are kept and named (`ProcessInfo.about/1`).
  `process_info` only: no call, no message to any process; a process that exited
  between sweeps is skipped.
- Runs in the panel's `start_async/3` task (the interval waits there).
- Tests (`test/phoenix_dev_toolbar/process_top_test.exs`): a process holding a
  large heap tops `:memory`, one with 500 queued messages tops `:queue`, a busy
  one shows in `:reductions`, an exited one is skipped, `max_processes: 1`
  refuses with the count, an unknown sort is refused.

## Task 2: the System tab

`#pdt-system-top`: the sort select and Read button (`top` event, one read a
second), the table (`pdt-table`), rows linking to the inspector, the refusal
as text. Tests in `system_panel_test.exs`.

## Docs

ADR 11 (Top decision as shipped), CHANGELOG line, roadmap tick 5e.

## Risks

- **Cost**: a sweep of every process is a few hundred ms at 100 000 processes, in a
  task, only on a click; the cap refuses bigger nodes. The task holds the sweep
  (three integers per process) only while it runs.
- **Memory in the panel**: 50 rows.
- **Host**: `process_info` only, the same reads the Process tab does.
