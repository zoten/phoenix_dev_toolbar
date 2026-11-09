# Phase 5d plan: supervision and application trees

Part of [the BEAM tools plan](./2026-11-09-beam-tools-roadmap-plan.md), ADR 11.
The ancestors chain shipped in 5b; this adds the forward direction. Two tasks.

## Scope

- **Children** of the inspected process when it is a supervisor (`Supervisor`,
  `:supervisor`, `DynamicSupervisor`, `PartitionSupervisor`, `Task.Supervisor`):
  counts (`count_children`), then the list (`which_children`): id, pid (a link:
  inspecting it pushes a crumb, so the tree is walked by navigation), type,
  modules. Read when the process is selected and on "Refresh", never polled.
  Above 200 children: counts only, the list is not read (it copies every child).
- **Applications**: the System tab's empty state lists the started applications,
  host apps and their deps first, then Elixir's, then OTP's (collapsed), each with
  its version and its top supervisor as a link. An "Applications" button brings
  the list back from any process.

## Task 1: `ProcessTree` (risky: calls into host processes, combined review)

`lib/phoenix_dev_toolbar/process_tree.ex` (`@moduledoc false`):

- `supervisor?(pid)`: `$initial_call` (one dictionary key, `ProcessInfo`) is
  `{:supervisor, _module, 1}` or `{DynamicSupervisor, :init, 1}`. Only these are
  ever asked: a GenServer without a `:which_children` clause would crash on it.
- `children(pid, timeout)`: `GenServer.call(pid, :count_children, timeout)` then, at
  200 active children or fewer, `GenServer.call(pid, :which_children, timeout)`
  (the messages `:supervisor.which_children/1` sends, with a timeout instead of
  `:infinity`). Returns `{:ok, counts, children | :too_many}` or
  `{:error, :timeout | :dead | :not_supervisor}`. Each child: `%{id, pid, type, modules}`
  with `id` inspected and truncated; `:restarting` and `:undefined` pids kept as such.
- `applications(timeout)`: `Application.started_applications/1` (a call to
  `application_controller`, with timeout), grouped `:host | :elixir | :otp` (OTP
  apps live under `:code.root_dir/0`; Elixir's are the `elixir`, `logger`, `eex`,
  `iex`, `mix`, `ex_unit` apps), each with its top supervisor from
  `:application_controller.get_master/1` (an ETS read) and
  `:application_master.get_child/1`, which waits without a timeout: run in a
  `Task` per application, `Task.yield_many/2` with the timeout, the rest killed.
  At most 100 applications.
- All of it runs in the panel's `start_async/3` tasks, never in the panel process.
- Tests (`test/phoenix_dev_toolbar/process_tree_test.exs`): a `start_supervised!`
  supervisor with children (counts, list, a restarting child), a DynamicSupervisor
  with 201 children (`:too_many`), a GenServer is not a supervisor and is never
  called (its mailbox stays empty), a busy supervisor times out, the application
  list holds `:phoenix_dev_toolbar` under `:host` with its top supervisor, and
  `:kernel` under `:otp`.

## Task 2: the System tab

- `panels/system.ex`: `#pdt-system-children` (counts, the list with pid links, a
  "Refresh" button, "N children: list not read" above the cap, errors as text),
  loaded with `start_async(:children, ...)` on select when `supervisor?/1`;
  `#pdt-system-apps` in the empty state (`start_async(:apps, ...)` when the tab is
  first shown with nothing selected, and on the "Applications" button, which
  clears the selection; crumbs stay).
- Tests in `system_panel_test.exs`: the children of a test supervisor, walking to a
  child, the applications list linking to `PhoenixDevToolbar.Supervisor`.

## Docs

ADR 11 (trees decision updated to what shipped), CHANGELOG line, roadmap tick 5d.

## Risks

- **Host crash**: a call to a non supervisor could crash it: strict `supervisor?/1`
  first, tested. **Host block**: every call has a timeout or runs in a task that is
  killed; the panel process never waits.
- **Memory**: children list capped at 200 (counts first), applications at 100,
  ids truncated.
- **Hot path / prod**: none; panel only.
