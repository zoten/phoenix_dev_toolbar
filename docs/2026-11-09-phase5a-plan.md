# Phase 5a plan: process addressing, protected set, client policy, navigation

Part of [the BEAM tools plan](./2026-11-09-beam-tools-roadmap-plan.md), ADR 10.
No user visible feature yet: the building blocks 5b (System tab) and 5c (actions)
need. Three tasks, each under ~40 turns.

## Decisions settled here

- **Actions are loopback only by default** (kill, suspend, message peek; reads and
  GC stay open as today). Top level config `actions:`:
  `:loopback` (default), `:any` (logs a warning at boot), `false` (no actions at all).
  Docker and LAN setups see a non loopback peer and must set `actions: :any`:
  the error shown in the panel says so.
- **Breadcrumbs move to 5b**, inside the System tab (the only tab that needs a
  history). 5a ships only the navigation primitive.

## Task 1: `ProcessRef`, `Protected`, `ClientPolicy` (risky: combined review)

New internal modules (`@moduledoc false`), all pure or read-only, unit tested.

- `lib/phoenix_dev_toolbar/process_ref.ex`: `parse(String.t()) :: {:ok, pid} | {:error, reason}`.
  - `"<0.123.0>"` or `"0.123.0"`: regex `^<?\d+\.\d+\.\d+>?$`, then
    `:erlang.list_to_pid/1` in `try` (no atoms). Reject non local node (`node(pid) != node()`).
  - Otherwise a registered name: `Enum.find(Process.registered(), &(Atom.to_string(&1) == input))`,
    also `"Elixir." <> input` for module names; `Process.whereis/1` on the found atom.
    Never `String.to_atom/1` or `to_existing_atom/1` (an attacker string must not be
    able to probe the atom table either).
  - Input capped at 128 bytes before any work.
  - Errors: `:invalid`, `:not_found`, `:remote`, `:dead`.
- `lib/phoenix_dev_toolbar/protected.ex`: `check(pid, context) :: :ok | {:error, reason_string}`,
  `context = %{panel: pid, transport: pid | nil, endpoint: module | nil}`.
  Protected when any holds:
  - `pid in [context.panel, context.transport]`
  - registered name in a fixed list: `init`, `erl_prim_loader`, `code_server`,
    `application_controller`, `kernel_sup`, `kernel_safe_sup`, `logger`,
    `logger_sup`, `user`, `standard_error`, `file_server_2`, `global_name_server`,
    `inet_db`, `rex`, `erts_code_purger`, `elixir_config`, `elixir_code_server`
  - `:application.get_application(pid)` in `[:kernel, :stdlib, :elixir, :logger, :compiler]`
  - toolbar's own: reuse the `PhoenixDevToolbar.` prefix rule of
    `ProcessInfo.relation/2` (`process_info.ex:181`): extract it to a public
    `ProcessInfo.toolbar?/1` and use it in both places
  - `Process.whereis(context.endpoint)` (the host endpoint's supervisor)
  Read paths never call it; it gates only kill and suspend (5c).
- `lib/phoenix_dev_toolbar/client_policy.ex`:
  - `loopback?(:inet.ip_address()) :: boolean`: `127.0.0.0/8`, `::1`,
    `::ffff:127.x.x.x` (`{0,0,0,0,0,0xFFFF,a,b}` with `a >>> 8 == 127`).
  - `actions_allowed?(peer | nil) :: :ok | {:error, :disabled | :not_loopback}` from
    `Application.get_env(:phoenix_dev_toolbar, :actions, :loopback)`; an invalid value
    is logged once and treated as `:loopback`.
- `PanelLive.mount/3` (`panel_live.ex:39`): on connected mount read
  `get_connect_info(socket, :peer_data)` (already requested, `panel_socket.ex:47`) and
  store `client_ip` in an assign. Nothing consumes it until 5c; how panels see it
  (a prop or a helper) is decided there.
- Boot warning for `actions: :any` in `PhoenixDevToolbar.Application` start, behind
  `enabled?/0`.
- Tests: `test/phoenix_dev_toolbar/process_ref_test.exs`,
  `protected_test.exs` (a `start_supervised!` Agent is not protected; `:code_server`,
  the test's own pid as panel, a registered toolbar process are),
  `client_policy_test.exs` (each address form, each config value; `Application.put_env`
  so the file is `async: false`).

## Task 2: `Panel.navigate/3` (public API)

- `lib/phoenix_dev_toolbar/panel.ex`: `@doc`, `@spec navigate(Socket.t(), atom(), map()) :: Socket.t()`.
  Sends `{:pdt_navigate, Atom.to_string(plugin_id), params}` to `self()` (the panel
  LiveView: components share its process) and returns the socket, for pipelines.
- `PanelLive.handle_info({:pdt_navigate, tab, params}, socket)`: when `tab` is in
  `socket.assigns.tabs`, assign `:tab` and deliver `{:navigate, params}` to that
  panel's `handle_info/2` with `Panel.send_now/4` (`panel.ex:102`, already used at
  `panel_live.ex:91`). Unknown or tab-less id: ignored. Params are bounded by the
  caller (documented: a small map of strings).
- Guide: a short "Linking to another tab" section in `guides/writing-a-plugin.md`.
- Tests: extend `test/support/tabbed_panel.ex` (or a new support panel) to call
  `navigate/3` on an event and record `{:navigate, params}`; a LiveView test asserts
  the active tab changed and the target received the params.
- CHANGELOG: `Panel.navigate/3: switch to another tab with params (ADR 10)`.

## Task 3: shared process view (refactor, low risk)

- Move the render helpers out of `lib/phoenix_dev_toolbar/panels/process.ex`
  (`vital/1` at 486, `relation_list/1` at 518, `peak`, `sparkline_label`, `count`,
  `bytes`, `words`, lines 486 to 545) into `lib/phoenix_dev_toolbar/process_view.ex`
  (function components, `@moduledoc false`). The Process panel imports it.
  Polling stays in the panel until 5b shows what the System tab really shares.
- DOM ids and output unchanged: `test/phoenix_dev_toolbar/process_panel_test.exs`
  passes untouched (that is the test of this task).

## ADR and docs updates

- ADR 10: move the loopback question from "Open limits" into the decision
  (`actions:` config); add `ProcessInfo.toolbar?/1` rule to the protected set.
- Roadmap: tick 5a when merged. Breadcrumbs listed under 5b instead of 5a.

## Risks

- **Hot path**: none, no telemetry touched.
- **Production footprint**: new modules are only called from the panel and the
  application start (already behind `enabled?/0`); the boot warning too.
- **Atoms**: `ProcessRef` compares strings to `Process.registered/0`; test that an
  unknown name leaves `:erlang.system_info(:atom_count)` unchanged.
- **Host isolation**: `:application.get_application/1` is `process_info(pid, :group_leader)`
  plus an `ets:match` on `ac_tab` (OTP 27 `application_controller.erl:454`): no call
  into `application_controller`, safe to run while it is busy.
- **Security**: a peer behind a local proxy reads as loopback (ADR 12 open limit,
  same here); `check_origin` and the signed panel session still apply.
- **Public API**: `Panel.navigate/3` documented with spec and guide entry.
- **Memory**: no new state beyond one `client_ip` assign.

## Verification

- Per task: `mix test <files>` and `mix compile --warnings-as-errors`.
- End: `mix precommit` with every checkpoint green; `mix dev` (or `PORT=4001`) to
  check the Process tab looks unchanged.
