# Human review checklist: modules that run in host processes or gate access

What this is: a guide for the owner's personal review of the code that runs inside the host app's processes or decides who may reach the toolbar. The code was written by AI agents. It is not a code summary and not a second audit.
How to use it: review the sections in order, 10 to 20 minutes each. Tick a box only after reading the "Held by" spot yourself. Anything that does not hold becomes an issue before publishing.
Citations are function names and quoted clauses, so they survive line shifts: find them with `grep -n`. Tests are cited by name: `grep -n 'test "name' <file>`.
Written against commit `09b9b01` (branch `pre-release-audit`).

## Known and accepted limits

Do not report these as findings; each is documented in the ADR named.

- [ ] A proxy or tunnel that rewrites the Host header cannot connect the panel; there is no `allowed_origins` option ([ADR 04](../adr/04-ui-delivery.md)).
- [ ] A Host without a port accepts an Origin on port 80 or 443, and the Origin scheme is not compared with the request's ([ADR 04](../adr/04-ui-delivery.md)).
- [ ] A host plug that adds `access-control-*` headers from a `register_before_send` registered earlier than ours can re-add them after our stripping ([ADR 04](../adr/04-ui-delivery.md)).
- [ ] Key based redaction does not see a secret inside a string value, a bare 2-tuple outside a list or a charlist key; Ecto params are positional, so an INSERT shows a password hash value ([ADR 03](../adr/03-event-storage.md)).
- [ ] Processes spawned without `$callers` (raw `spawn`, GenServers) are not attributed, and `handle_info/2` has no telemetry event ([ADR 02](../adr/02-telemetry-collection-and-correlation.md)).
- [ ] A proxy that adds no forwarding header (Docker's userland port proxy, a plain TCP tunnel) reads as loopback; loopback then means "whoever reaches the proxy" ([ADR 10](../adr/10-process-addressing-and-actions.md), [ADR 12](../adr/12-cluster-and-eval-plugins.md)).
- [ ] Message peek, the trace and Read state copy data out of the target (a flooded queue between two reads, large messages, a whole state) before redaction; a suspended process holding a lock stalls its waiters until the TTL; endpoint children and the Repo pool are not protected ([ADR 10](../adr/10-process-addressing-and-actions.md), [ADR 11](../adr/11-system-tab.md)).
- [ ] EXPLAIN plans and params can quote secrets (redaction is by key only); EXPLAIN holds a pool connection for up to 5 s; `UNION (`, `VALUES` and `TABLE` queries are not explained ([ADR 08](../adr/08-query-diagnostics.md)).
- [ ] Evaluated code is the developer's: it may create atoms, spawn processes the timeout does not stop, run commands or halt the node ([ADR 12](../adr/12-cluster-and-eval-plugins.md)).
- [ ] The panel's JS runs only in a real browser; CI does not execute it, so the loader and panel checks below are manual ([ADR 04](../adr/04-ui-delivery.md)).

## 1. Application and `enabled?/0`

Files: `lib/phoenix_dev_toolbar/application.ex`, `lib/phoenix_dev_toolbar.ex`. Governing ADR: [ADR 01](../adr/01-zero-prod-footprint-and-installation.md). Runs in: the host's application start (the VM's application master), then every caller of `enabled?/0`.

**Must hold**
- [ ] With `enabled` unset and Mix env other than `:dev` (or Mix not loaded), the toolbar turns itself off and logs why.
  Held by: `settle_enabled/2` (`def settle_enabled(:error, mix_env)` puts `enabled: false`).
  Proved by: `test/phoenix_dev_toolbar/application_test.exs`, "unset anywhere else disables the toolbar and says why".
- [ ] An explicit `enabled` value is never overridden.
  Held by: `settle_enabled/2` (`def settle_enabled({:ok, _explicit}, _mix_env), do: :ok`).
  Proved by: `application_test.exs`, "an explicit value wins in any env".
- [ ] Disabled means no supervisor child (no Store, no ETS tables, no Suspender, no Tracer).
  Held by: `children/1` (`def children(false), do: []`).
  Proved by: `application_test.exs`, "disabled starts no children, enabled starts the stores".
- [ ] Disabled means no telemetry handler is attached.
  Held by: `maybe_attach/1` (`def maybe_attach(false), do: :ok`).
  Proved by: `application_test.exs`, "disabled attaches no telemetry handlers".
- [ ] Only the literal `true` enables the toolbar (a string, `nil` or `1` does not).
  Held by: `PhoenixDevToolbar.enabled?/0` (`Application.get_env(:phoenix_dev_toolbar, :enabled, true) == true`).
  Proved by: no test (the existing tests use booleans only).
- [ ] With the dependency declared `only: :dev`, a `MIX_ENV=prod` build does not contain the toolbar modules or handlers.
  Held by: dependency scoping in `fixtures/host_app/mix.exs` (`only: :dev`) and the install shape in the README.
  Proved by: CI step "Fixture host app boots without Ecto" running `fixtures/host_app/check_boot.exs` (not an ExUnit test).
- [ ] Application stop detaches the handlers.
  Held by: `prep_stop/1` calling `Collector.detach()`.
  Proved by: no test of `prep_stop/1`; `collector_test.exs` "detach/0 removes every toolbar handler" covers `detach/0` only.

**Look closely at**
- `settle_enabled/2` mutates the application env with `Application.put_env` at boot, and `enabled?/0` reads the env on every call: confirm that nothing later flips it back to `true` while the children stay absent.
- `mix_env/0` calls `Mix.env()` at runtime, guarded by `Code.ensure_loaded?(Mix)`: check what it returns under `iex -S mix` with `MIX_ENV=prod` and in a release that bundles Mix.
- `Supervisor.start_link` runs before `maybe_attach(true)`: look at what a host's first request does between the two.

**Try by hand**
- Dependency without `only: :dev`: in `fixtures/host_app/mix.exs` remove `, only: :dev` from the `:phoenix_dev_toolbar` line, then `cd fixtures/host_app && MIX_ENV=prod mix deps.get && MIX_ENV=prod mix run -e 'IO.inspect({PhoenixDevToolbar.enabled?(), Process.whereis(PhoenixDevToolbar.Store)})'`. Expect `{false, nil}` and a warning mentioning `only: :dev`. Revert with `git checkout fixtures/host_app/mix.exs`.
- Normal install: `cd fixtures/host_app && MIX_ENV=dev mix run check_boot.exs` and `MIX_ENV=prod mix run check_boot.exs` (after reverting). Expect `ok:` lines and exit code 0 in both.

## 2. `PhoenixDevToolbar.Plug`

Files: `lib/phoenix_dev_toolbar/plug.ex`. Governing ADRs: [ADR 01](../adr/01-zero-prod-footprint-and-installation.md), [ADR 04](../adr/04-ui-delivery.md). Runs in: the host's request process (Bandit/Cowboy connection process), inside the endpoint, before the router.

**Must hold**
- [ ] When the toolbar is disabled, the plug neither answers nor alters any request, its own paths included.
  Held by: `call/2` (`false -> conn`).
  Proved by: `test/phoenix_dev_toolbar/plug_test.exs`, "everything, when the toolbar is disabled" and "its own paths pass through, not halted and not answered".
- [ ] The panel, the socket upgrade and the export are served only after the Host check; assets are the only public route.
  Held by: `guarded/3` (`case HostCheck.allowed?(conn) do`), used by the `["panel"]`, `["export", "ecto.json"]` and `["live", "websocket"]` clauses of `route/2`.
  Proved by: `host_check_test.exs`, "the plug refuses the panel for a refused host, and says how to allow it" and "the export path is refused for a refused host too"; `panel_socket_test.exs`, "a Host that could be rebound gets 403 on the upgrade".
- [ ] Only a top level `GET` document is tracked, and only a 200 `text/html` `send_resp` body with identity encoding and a `</body>` is modified.
  Held by: `page_request?/1`, `top_level_document?/1` (`sec-fetch-dest`, else `accept`), `maybe_inject/3` (`state: :set, status: 200`, `html?/1`, `identity_encoding?/1`).
  Proved by: `plug_test.exs`, "count as pages only for top level documents, by sec-fetch-dest", "non HTML content types, non 200 statuses and bodies without </body>", "compressed bodies", "file responses", "chunked responses", "non HTML requests, iframes, partial fetches and live reload frames".
- [ ] A failure in the response hook (error, throw or exit) leaves the response untouched and never escapes into the host's `send_resp`; the connection process is released from the `$callers` index either way.
  Held by: `before_send/2` (the `catch` clause with `kind, reason ->`, and the `after` block calling `Attribution.forget_pid()`).
  Proved by: `plug_test.exs`, "a #{kind} in the response hook leaves the response untouched and the process untracked" (generated for `:throw` and `:exit`), "a failing response hook is logged once per failure class", "every request, without crashing, while the Store is down".
- [ ] A keep-alive connection process never carries one request's sid into the next.
  Held by: `untracked/1` calling `Attribution.untrack()`, applied in `maybe_track/2` and every non page branch.
  Proved by: `plug_test.exs`, "clear the previous request's sid from a reused connection process" and "keep the mark after the response but stop being a $callers parent".
- [ ] Injected tag attributes are HTML escaped and asset URLs come from the configured `:path`, never from the request path.
  Held by: `loader_tag/3` (`Plug.HTML.html_escape(value)`), `refuse/2` (`Plug.HTML.html_escape`).
  Proved by: `plug_test.exs`, "use the configured path and the CSP nonce assign"; `layouts_test.exs`, "builds asset URLs from the configured path, never from the request path".
- [ ] Only the whitelisted files are served under `/assets/`, and a host CORS plug cannot open the panel or the export to another origin.
  Held by: `serve_asset/2` (`%{^file => {app, source, content_type}} <- @assets`), `strip_cors/1`.
  Proved by: `plug_test.exs`, "files outside the whitelist are a 404" and "are stripped from the panel, the export and a refusal".

**Look closely at**
- `route/2` ordering: `{:ok, _rest} -> untracked(conn)` lets unknown paths under the toolbar path fall through to the host router. Check that `//__pdt/panel` and trailing slashes reach the same clauses as `/__pdt/panel` (`strip_prefix/2` works on `conn.path_info`).
- `maybe_inject/3` does `IO.iodata_to_binary(body)` and `:binary.matches(body, "</body>")` on every tracked 200 HTML response: cost on large pages, and the last match being used when `</body>` appears inside a script string.
- Callback order: Plug runs `register_before_send` callbacks in reverse registration order, so the hook sees the body as left by hooks registered after it. Compare with `Phoenix.LiveReloader`.
- `refuse/2` writes the Host header (attacker controlled) into HTML: follow `String.slice(0, 100)` and `Plug.HTML.html_escape` and the `allowed_hosts: ["..."]` string.

**Try by hand** (`PORT=4001 mix dev`, then ...)
- `curl -s -H 'Sec-Fetch-Dest: document' http://localhost:4001/plain | grep -o '<script defer[^>]*>'`: expect exactly one tag with `data-pdt-sid` and `data-pdt-path="/__pdt"`. Repeat with `-H 'Sec-Fetch-Dest: iframe'`: expect no tag.
- `curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:4001/__pdt/panel` expect `405`; `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4001/__pdt/assets/secret.js` expect `404`.
- Disabled: in `dev.exs`, after the line `Application.put_env(:phoenix_dev_toolbar, :actions, :loopback)`, add `Application.put_env(:phoenix_dev_toolbar, :enabled, false)` and restart. Expect the first curl to return no script tag and `/__pdt/panel?sid=x` to be answered by the host router (a Phoenix 404 page), not by the toolbar. The children still run in this harness; only the plug's gate is shown.

## 3. `HostCheck` and `PanelSocket`

Files: `lib/phoenix_dev_toolbar/host_check.ex`, `lib/phoenix_dev_toolbar/panel_socket.ex`. Governing ADR: [ADR 04](../adr/04-ui-delivery.md). Runs in: the host's request process (the HTTP upgrade), then the WebSocket connection process (a `WebSock` wrapping the LiveView socket handler).

**Must hold**
- [ ] A Host that can be rebound is refused: only an IP literal, `localhost`, `*.localhost`, the endpoint's `url: [host: ...]` or an `allowed_hosts:` entry passes.
  Held by: `HostCheck.allowed?/1` (`ip?(host) or localhost?(host) or host == endpoint_host(conn) or listed?(host)`).
  Proved by: `host_check_test.exs`, "IP literals and localhost names cannot be rebound: allowed", "any other name is refused: a rebound attacker domain looks like this", "the endpoint's own url host is allowed", "allowed_hosts: exact names, and suffixes starting with a dot".
- [ ] A socket upgrade needs exactly one `Origin` (http or https) whose host equals the Host header's host and whose port matches the Host's port.
  Held by: `same_origin?/1`, `request_authority/1`, `port_matches?/2`, applied by `check_origin/1` before `connect/4`.
  Proved by: `panel_socket_test.exs`, "a foreign origin is refused even when the host socket has check_origin: false", "a missing origin is refused", "the Host header decides: IPv6 literals, case and ports", "scheme, host and port must be sane: other hosts, ports and schemes are refused", "no Host header falls back to the request host, several Host headers are refused", "a foreign or missing origin is refused over a real socket".
- [ ] Through this socket only a registered panel LiveView can be joined; a host LiveView's session token gets `stale`, and any other topic, binary frame or garbage closes the connection.
  Held by: `check/2` (every text frame decoded, `phx_join` only), `join/3` (`Store.panel_allowed?(id)`; `defp join("phoenix", _join_ref, _ref)` is the only other topic).
  Proved by: `panel_socket_test.exs`, "a host LiveView cannot be joined through the panel socket", "an escaped event name is still a join (decoded before the check)", "a second join on a panel's connection is checked too", "a panel the Store forgot gets stale, not a silent close", "a join with extra elements closes; duplicate keys read as the serializer does", "other topics, binary frames and garbage close the connection".
- [ ] The socket carries no host session, so LiveView skips its session and CSRF paths and the panel reads nothing from the user's login.
  Held by: `@connect_info [:peer_data, :uri, :user_agent, :x_headers]` (no `:session`) passed to `Transport.connect_info/3` in `connect/4`.
  Proved by: `panel_socket_test.exs`, "the panel joins through its own socket with no cookie and no CSRF token".
- [ ] An endpoint without a mounted LiveView socket gets a 404, not a crash; a non upgrade request gets 400, not a crash.
  Held by: `upgrade/1` (the `nil ->` branch answers 404), `connect/4` (`rescue` of `WebSockAdapter.UpgradeError` answers 400).
  Proved by: `panel_socket_test.exs`, "an endpoint without a LiveView socket gets a 404, never a crash" and "a request that is not a WebSocket upgrade is refused".
- [ ] Refusal logging is bounded: once per host or pair, at most 10 distinct values, client values inspected with limits.
  Held by: `HostCheck.log_refused/1`, `PanelSocket.log_refused/1` (`length(logged) >= @max_logged`, `header_for_log/2`).
  Proved by: `host_check_test.exs`, "logs each host once" and "names at most 10 distinct hosts"; `panel_socket_test.exs`, "a refusal names the Origin and the Host, once per pair".

**Look closely at**
- `HostCheck.allowed?/1` reads `conn.host`: confirm what it holds when the host app runs `Plug.RewriteOn` or a proxy plug earlier in the endpoint.
- `matches?/2` suffix rule (`"." <> _suffix` with `String.ends_with?`) and `localhost?/1` (`.localhost`): think about trailing dots and an `allowed_hosts` entry of just `"."`.
- `port_matches?(origin_port, nil)` and `request_authority/1` (`URI.parse("//" <> authority)` on an attacker controlled Host header): userinfo and odd ports.
- `check/2` has a catch all `{:ok, [_join_ref, _ref, _topic, event, _payload]} when is_binary(event) -> :ok`: every non join event, for any topic, goes to the LiveView handler. Look at what LiveView does with an `event` or `phx_leave` for a topic that was never joined.

**Try by hand** (`PORT=4001 mix dev`, then ...)
- Rebinding guard: `curl -s -H 'Host: evil.example' 'http://localhost:4001/__pdt/panel?sid=x' | grep -o 'id="pdt-refused"'` expect a match and status 403 (add `-o /dev/null -w '%{http_code}'` to see it). In `dev.exs` add `Application.put_env(:phoenix_dev_toolbar, :allowed_hosts, ["evil.example"])` before `Application.put_env(:phoenix_dev_toolbar, :actions, :loopback)`, restart: the same curl now returns 200.
- Origin rule: `curl -s -m 2 -o /dev/null -w '%{http_code}\n' -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Origin: http://evil.example' 'http://localhost:4001/__pdt/live/websocket?vsn=2.0.0'` expect `403`; with `-H 'Origin: http://localhost:4001'` expect `101`; without any Origin header expect `403`. The server log shows one `refused a panel socket request` line per distinct pair.
- Join gate, in the console of `http://localhost:4001/counter`: `ws = new WebSocket("ws://localhost:4001/__pdt/live/websocket?vsn=2.0.0"); ws.onmessage = e => console.log(e.data); ws.onclose = () => console.log("closed"); ws.onopen = () => ws.send(JSON.stringify(["1","1","lv:phx-nope","phx_join",{}]))`. Expect a reply with `"status":"error"` and `"reason":"stale"`. Then `ws.send(JSON.stringify(["2","2","chan:x","phx_join",{}]))`: expect `closed`.

## 4. `ClientPolicy`, `ProcessActions` and `Protected`

Files: `lib/phoenix_dev_toolbar/client_policy.ex`, `lib/phoenix_dev_toolbar/process_actions.ex`, `lib/phoenix_dev_toolbar/protected.ex` (callers: `process_controls.ex`, `panels/system.ex`, `panel_live.ex` `client_ip/1`). Governing ADR: [ADR 10](../adr/10-process-addressing-and-actions.md). Runs in: the panel LiveView process (kill and suspend are issued from it against host pids); `Process.exit/2` and the Suspender call are made from the panel.

**Must hold**
- [ ] With `actions` unset, `false` or any invalid value, nobody can kill, suspend, peek or read state.
  Held by: `ClientPolicy.mode/0` (`_off_or_invalid -> false`), `check_actions/1` (`false -> {:error, :disabled}`).
  Proved by: `client_policy_test.exs`, "by default nobody may act, and the default does not warn", "actions: false lets nobody act", "an invalid value counts as off, and warns"; `process_actions_test.exs`, "with actions unset nobody acts, and the message names the option".
- [ ] `actions: :loopback` lets only a panel whose socket peer is a loopback address act; a join carrying a proxy header has no client address.
  Held by: `ClientPolicy.loopback?/1` (IPv4, IPv6, IPv4 mapped), `PanelLive.client_ip/1` (`{%{address: address}, false} -> address`, `proxied?/1` over `x-forwarded-for`, `x-forwarded-host`, `x-forwarded-proto`, `x-real-ip`).
  Proved by: `client_policy_test.exs`, "loopback addresses" and "actions: :loopback lets only loopback clients act"; `panel_socket_test.exs`, "a direct join is a loopback client; one with X-Forwarded-For is not"; `system_panel_test.exs`, "a browser off this machine gets no actions, and is told how to allow them".
- [ ] The policy is enforced where the action runs, not only by hiding buttons.
  Held by: `ProcessActions.kill/3` and `suspend/2` (both call `allowed/2`, which calls `client/1`), `peek/2` (`with :ok <- client(context)`), `Panels.System` read state (`not ProcessControls.client?(socket) ->` sets `{:error, :policy}`), `start_trace/1` (`ProcessActions.allowed(pid, ProcessControls.context(socket))` before `Tracer.start`).
  Proved by: `process_actions_test.exs`, "a client off this machine may not act, and is told how to allow it". No test sends a forged kill, suspend or trace event to the panel with actions off; `system_panel_test.exs` asserts that the buttons are absent.
- [ ] Kill and suspend are refused for the panel, its transport, the host endpoint, toolbar processes, core OTP processes, application masters and processes of `kernel`, `stdlib`, `elixir`, `logger`, `compiler`.
  Held by: `Protected.check/2` (`cond` over `context.panel`, `context[:transport]`, `endpoint?/2`, `ProcessInfo.toolbar?/1`, then `core/1`, `master/1`, `application/1`).
  Proved by: `protected_test.exs`, "the panel and its connection are protected", "the host endpoint is protected", "the toolbar's own processes are protected", "core OTP processes are protected, by name or by application", "application masters are protected", "another node's process is refused"; `process_actions_test.exs`, "a protected process is never killed" (kill only; no test for suspend on a protected pid).
- [ ] A kill reason from the browser is matched against a fixed list of strings and never turned into an atom.
  Held by: `ProcessActions.exit_reason/1` (`"kill"`, `"shutdown"`, `"crash"`, `defp exit_reason(_other)` returns an error).
  Proved by: `process_actions_test.exs`, "an unknown reason kills nothing".
- [ ] Every kill and suspension is logged at warning level.
  Held by: `Logger.warning` in `kill/3` and `suspend/2`.
  Proved by: `process_actions_test.exs`, "kill with a crash exits like a crash, and is logged", "suspend and resume, logged".
- [ ] Message peek never reads a queue of 100 or more messages and shows at most 10 messages, redacted and truncated.
  Held by: `peek/2` (`when length < @peek_below`), `read_messages/1` (`Enum.take(@peek_count)`, `Truncate.redact()`, `Truncate.inspect_value()`).
  Proved by: `process_actions_test.exs`, "peek shows the first messages, redacted, under a queue limit".

**Look closely at**
- `PanelLive.client_ip/1`: the address is `peer_data` of the websocket as the panel socket saw it; a header based proxy test is the only protection against a local reverse proxy, and `proxied?/1` lists four names.
- `ClientPolicy.explicitly_off?/0` (`Application.fetch_env(...) == {:ok, false}`) versus `mode/0`: Eval depends on the difference between unset and `false`.
- `Protected.check/2` order and `endpoint?/2` (`Process.whereis(endpoint) == pid`): the endpoint's children are deliberately not protected (ADR 10 limit), the listener's supervisor is the question to ask.
- `ProcessActions.read_messages/1`: `Process.info(pid, :messages)` copies the whole queue after the length check.

**Try by hand** (`PORT=4001 mix dev`, then ...)
- The harness sets `actions: :loopback`. Open `http://localhost:4001/counter`, pick the `#pdt-tab-system` tab, type `code_server` in `#pdt-system-search` and submit: expect no `#pdt-system-kill` and a "Protected" explanation. Search a page LiveView pid (copy it from the Process tab), click `#pdt-system-suspend` then `#pdt-system-confirm`, then click `#click` on the page: it should not update for about 10 s, and the server log shows `suspended #PID<...>`.
- In `dev.exs` change `Application.put_env(:phoenix_dev_toolbar, :actions, :loopback)` to `:everyone`, restart. Expect an `invalid actions` warning in the log, `#pdt-system-actions-off` in the System tab and no `#pdt-system-kill`, `#pdt-system-peek` or `#pdt-system-status`.

## 5. `Collector`, `Tracker` and `Attribution`

Files: `lib/phoenix_dev_toolbar/collector.ex`, `lib/phoenix_dev_toolbar/tracker.ex`, `lib/phoenix_dev_toolbar/attribution.ex`. Governing ADR: [ADR 02](../adr/02-telemetry-collection-and-correlation.md). Runs in: whichever host process emits the telemetry event (request process, LiveView process, Repo caller, `Task` children); `attach/1` runs in the application start.

**Must hold**
- [ ] An untracked process returns without reaching any plugin code: two process dictionary reads, then `$callers` lookups.
  Held by: `Collector.handle_event/4` (`case Attribution.current() do`, branch `nil -> :ok`), `Attribution.current/0`, `from_callers/1`.
  Proved by: `collector_test.exs`, "ignores events from untracked processes" and "an untracked process never reaches a plugin's collect/3".
- [ ] The handler never raises, throws or exits, whatever the Store, Notify or event metadata do.
  Held by: `handle_event/4` (the `catch` clause with `kind, reason ->` calls `log_failure/5`).
  Proved by: `collector_test.exs`, "survives the Store being down and stays attached" and "malformed mount metadata is logged once and the handler stays attached".
- [ ] A plugin whose `collect/3` raises is quarantined and logged once; other plugins keep working.
  Held by: `run_plugin/4` (`catch` into `quarantine/5`), `collect/4` (`not quarantined?(plugin)`).
  Proved by: `collector_test.exs`, "quarantines a raising plugin, logs once and keeps the others working", "attach/1 releases quarantined plugins".
- [ ] A recorded event is stamped with its own plugin's id and the current span; a plugin cannot write into another plugin's tab or cap.
  Held by: `collect_one/5` (`%{recorded | plugin: id, span: context.span}`).
  Proved by: `plugin_quarantine_test.exs`, "an event recorded under another plugin's id is stamped with its own".
- [ ] A plugin with a failing `init/1`, a bad `telemetry_events/1` or malformed event names is skipped and logged; `attach/1` never raises in the host's application start.
  Held by: `start/2` (the `catch` clause with `kind, reason ->` calls `skip/2`), `event_name?/1`, `normalize/1`.
  Proved by: `collector_test.exs`, "leaves out, with an error log, a plugin whose init/1 fails", "skips a plugin with malformed event names instead of failing the attach", "garbage entries given to attach/1 directly are skipped".
- [ ] The handler config copied into every emitting process holds module names only; plugin configs are read from `:persistent_term` once the process is known to be tracked.
  Held by: `attach/1` (`:telemetry.attach({Collector, event}, event, &Collector.handle_event/4, event_plugins)`) and `collect/4` (`:persistent_term.get(@configs_key, %{})`).
  Proved by: `collector_test.exs`, "the handler config holds module names only, never plugin configs".
- [ ] The toolbar's own LiveViews are never tracked (no feedback loop of the panel observing itself).
  Held by: `Tracker.live_view_mount/2` (`own_view?(info.view)`, prefix `Elixir.PhoenixDevToolbar.`).
  Proved by: `tracker_test.exs`, "never tracks the toolbar's own LiveViews".

**Look closely at**
- `maybe_track(@mount_start, ...)` runs for every process on every `[:phoenix, :live_view, :mount, :start]`, tracked or not, before the attribution check: it calls `Tracker.live_view_mount/2`, `LiveViewCompat.info/1` and ETS lookups in every host LiveView mount.
- `Attribution.next_span/0` costs a `Process.put` and an ETS `update_element` at each LiveView callback edge in tracked processes; `from_callers/1` does one ETS lookup per pid in `$callers`.
- `Collector.quarantine/5` and `log_failure/5` use `:persistent_term.put`, expensive but once per key: check the keys are bounded (plugin module, `{scope, kind, exception module or :other}`).
- `Tracker.rejoin?/3` uses `Process.alive?(owner)` to tell rejoin from navigation: the tests "a reconnect on a new transport claims the session of the dead owner" and "a duplicated tab does not steal the session of a live owner" are the cases to read.

**Try by hand** (`PORT=4001 mix dev`, then ...)
- Open `http://localhost:4001/plugins` (Plugin errors) with the panel open. Click `#flaky-collect`: the host page keeps working, the log shows one `plugin Demo.FlakyPlugin (now disabled) raised`, and the Flaky tab shows `#pdt-disabled-flaky` with `#pdt-reenable-flaky`. Click `#flaky-collect` again: no second log line.
- With the log visible, click `#click` on `http://localhost:4001/counter` and reload several times: the host page must behave as with the toolbar excluded, and no `collector raised` line appears.

## 6. `Store`

Files: `lib/phoenix_dev_toolbar/store.ex`. Governing ADR: [ADR 03](../adr/03-event-storage.md). Runs in: the writer is the host process (ETS only, plus `GenServer.cast` for trims); the GenServer owns the tables and runs sweeps, trims and monitors.

**Must hold**
- [ ] The write path never calls the Store GenServer synchronously and does no I/O; a missing table (Store restarting) loses the event and nothing else.
  Held by: `insert/3` (only `:ets.update_counter` and `:ets.insert`; `maybe_request_trim/4` uses `GenServer.cast`; the `rescue` of `ArgumentError` returns `:no_session`).
  Proved by: `collector_test.exs`, "survives the Store being down and stays attached"; `plug_test.exs`, "every request, without crashing, while the Store is down". No test asserts the absence of synchronous calls.
- [ ] Events per plugin and per session are capped, and the oldest are trimmed first; a chatty plugin only trims its own events.
  Held by: `maybe_request_trim/4`, `trim/3`, `@trim_every`.
  Proved by: `store_test.exs`, "trims the oldest events of a plugin down to max_events", "a chatty plugin never trims another plugin's events", "the session ceiling trims the oldest events of any plugin".
- [ ] A flood is cut by a per second budget per session and counted as dropped.
  Held by: `within_rate?/3` (`:ets.update_counter(@rate, key, 1, {key, 0}) <= max`), `count_dropped/1`.
  Proved by: `store_test.exs`, "drops events over the per-second budget and counts them".
- [ ] Sessions are capped (those without a live LiveView owner go first) and expire by TTL; a LiveView session goes away after its owner exits.
  Held by: `evict_oldest/0`, `do_sweep/1` (`not live_owner?(session)`, `now_us - last_activity(session) > ttl_us`), `expire/2`.
  Proved by: `store_test.exs`, "evicts the oldest sessions beyond max_sessions", "evicts sessions without a live LiveView owner first", "expires idle request sessions after the TTL, measured from the last event", "never expires a LiveView session whose owner is alive", "drops the session and its indexes when the owner exits".
- [ ] The panel allowlist that gates the panel socket holds at most 1000 ids and drops entries after a day.
  Held by: `allow_panel/1` (`evict_panel(:ets.info(@panels, :size) >= @max_panels and not :ets.member(@panels, id))`), `expire_panels/0` (`@panel_ttl_s`).
  Proved by: `store_test.exs`, "never holds more than 1000 panels, and the newest is always in" and "registering a panel again at the cap evicts nobody". No test of the one day expiry.
- [ ] Limit overrides that are not positive integers (or 0 for `ttl_ms` and `down_grace_ms`) keep the default; `:infinity` never disables a cap.
  Held by: `put_configured_limits/0` calling `Config.limits/2` (`valid_limit?/2`).
  Proved by: `config_test.exs`, "an invalid value keeps that key's default, with a warning" (under `describe "limits/2"`).

**Look closely at**
- The tables are `:public` (`shared_opts/0`): any process in the VM, including evaluated code, can write them. Check no code path trusts a row without validating it, in particular `@panels` (it gates the socket) and `@pids`/`@socket_ids`.
- `do_insert/3` bumps the session counter, then the plugin counter, then reads `:atomics` and inserts: look at a host process killed between the steps (ADR 03 lists the one off counters) and at `maybe_request_trim/4` firing only when `rem(count - max, @trim_every) == 1`.
- `evict_oldest/0` and `delete_orphan_events/0` walk whole tables inside the GenServer: how long a sweep holds the Store with 50 sessions of 2000 events.
- `Store.sweep/1`, `put_limits/1` and `reset/0` are test helpers still public: see whether any non test code reaches them.

**Try by hand** (`PORT=4001 mix dev`, then ...)
- Create sessions: `for i in $(seq 1 80); do curl -s -o /dev/null -H 'Sec-Fetch-Dest: document' http://localhost:4001/plain; done`. Open `http://localhost:4001/counter`, tab `#pdt-tab-eval` (the harness has `allow: :eval`), run `{:ets.info(:pdt_sessions, :size), :ets.info(:pdt_events, :size), :ets.info(:pdt_panels, :size)}` in `#pdt-eval-code` with `#pdt-eval-run`. Expect the first number at most 50 (the `max_sessions` default) and the second at most 50 times 2000.

## 7. `Truncate`

Files: `lib/phoenix_dev_toolbar/truncate.ex`. Governing ADR: [ADR 03](../adr/03-event-storage.md). Runs in: host processes (plugin `collect/3`, called from the Collector) and the panel's tasks (`snapshot/1`).

**Must hold**
- [ ] `redact/2` returns `"[REDACTED]"` for a sensitive key's value and never returns an unvisited value as is: whatever the walk does not reach becomes `"…"`.
  Held by: `do_redact/3` (`when budget <= 0, do: {@cut, 0}`), `redact_split/3`, `first_entries/2`.
  Proved by: `truncate_test.exs`, "never returns an unvisited sensitive value, however it is hidden", "a deeply nested sensitive key is still redacted within the budget".
- [ ] The redaction walk is bounded: at most 1000 nodes and 50 entries per container, key names matched on their first 256 bytes.
  Held by: `@redact_nodes`, `@list_items`, `key_prefix/1` (`valid_prefix(key, @key_prefix)`).
  Proved by: `truncate_test.exs`, "a wide and deep value is walked within a fixed node budget", "a 1 MB key is matched on a bounded prefix", "a key whose prefix cut lands mid codepoint does not raise".
- [ ] `preview/3` walks at most 200 nodes and 20 items per container, and its output is capped at 360 bytes; a sensitive key past the budget is cut, never shown.
  Held by: `preview/3` (`prune(value, @preview_nodes, redact)` then `inspect_value(@change_inspect) |> string(bytes)`), `prune/3`.
  Proved by: `truncate_test.exs`, "cost and size are bounded however deep the value", "100 strings of 5 KB stay under the byte cap", "a sensitive key past the walk budget is cut, never shown".
- [ ] An assigns diff stores at most 20 keys and 10 values, about 4 KB, however large the assigns; `flash` is listed without its value.
  Held by: `changes/2` (`Enum.split(@change_keys)`, `Enum.take(shown, @change_values)`, `key != :flash`).
  Proved by: `truncate_test.exs`, "is bounded: 20 keys, 10 values, about 4 KB however large the assigns", "flash is listed but its value is not stored".
- [ ] SQL is capped at 8 KB and other text at 2 KB without splitting a UTF-8 codepoint; stacktraces keep 10 frames without toolbar or `:telemetry` frames.
  Held by: `sql/1`, `string/2`, `valid_prefix/3`, `stacktrace/2`.
  Proved by: `truncate_test.exs`, "caps long SQL and marks it truncated", "never splits a UTF-8 codepoint", "drops toolbar and telemetry frames and keeps at most 10".
- [ ] A banner is built without raising even when an exception's `message/1` raises or throws, and throw or exit reasons are inspected with limits.
  Held by: `banner/2` (the `catch` clause with `_kind, _reason ->`), `format_banner/2`.
  Proved by: `plugin_quarantine_test.exs`, "a banner survives an exception whose message/1 throws".
- [ ] No atom is created from runtime input.
  Held by: the module has no `String.to_atom`, `binary_to_term` or similar (`grep -rn 'to_atom' lib` returns nothing; the only runtime parse is `:erlang.list_to_pid/1` in `process_ref.ex`).
  Proved by: no test.

**Look closely at**
- `redact/2` returns scalars as they are, including a large binary or a secret in a string value (documented limit): check each caller that stores a redacted value also passes it through `inspect_value/2` or `string/2`.
- `prune/3` clause for structs (`walk_field?/2`, `Map.to_list(struct)`): a struct with scalar fields keeps its own `Inspect`; look at a custom `Inspect` implementation that prints a field the key match did not see.
- `redact_keys/0` reads `Application.get_env(:phoenix_dev_toolbar, :redact, [])` on every call, and `List.wrap/1` of a non list value: see what an unexpected value does.
- `redact/2`'s default argument `keys \\ redact_keys()` versus `preview/3`'s lowercased list: confirm both lowercase the configured keys.

**Try by hand** (`PORT=4001 mix dev`, then ...)
- Eval tab on any harness page, run `PhoenixDevToolbar.Truncate.redact(%{"user" => %{"password" => "hunter2", "name" => "Ada"}, "items" => Enum.to_list(1..100)})`. Expect `"password" => "[REDACTED]"` and the items list ending with `"…"` after 50 elements.
- `http://localhost:4001/assigns`, click `#grow` (adds 100k items to assigns), open the LiveView tab: the assigns diff and values stay short (about 4 KB) and the page does not freeze.

## 8. `Explain`

Files: `lib/phoenix_dev_toolbar/explain.ex` (callers: `plugins/ecto.ex` `Explain.capture`, `panels/ecto.ex`, `ecto_export.ex`). Governing ADR: [ADR 08](../adr/08-query-diagnostics.md). Runs in: `capture/3` in the Repo caller's process (inside `collect/3`); `run/2` in the panel's `start_async/3` task, or the request process for the export, and it uses a connection from the host's Repo pool.

**Must hold**
- [ ] Only a single `SELECT` or `WITH` statement is ever run, without MySQL versioned comments, backslashes or a `;` outside quotes and comments.
  Held by: `run/2` (`single_select/1`, `select?/1`, `separator?/1`).
  Proved by: `explain_test.exs`, "refuses what it must not run" (UPDATE, `SELECT 1; DELETE ...`, `/*!80018`, backslash, and a final assertion that `users` still has 2 rows) and "semicolons in strings, identifiers or comments, or a trailing one, are fine".
- [ ] Only a query that already succeeded is explained (a failed one could hide a comment that turns the prefix into `EXPLAIN ANALYZE`), and only for a configured repo.
  Held by: `run/2` (`succeeded/1`, `configured/2`).
  Proved by: `explain_test.exs`, "refuses what it must not run" (`:query_failed`, `:repo_not_configured`).
- [ ] The statement is prefixed with `EXPLAIN` or `EXPLAIN QUERY PLAN`, never `ANALYZE`, and unknown adapters get no prefix.
  Held by: `prefix/1`.
  Proved by: `explain_test.exs`, "refuses what it must not run" (`:unsupported_adapter`); no test asserts the prefix text.
- [ ] Execution is inside a transaction that is always rolled back, with a 5 s timeout (and `statement_timeout` on Postgres); the plan is truncated.
  Held by: `explain/3` (`repo.rollback(query(repo, sql, params))`, `@timeout`, `SET LOCAL statement_timeout`), `query/3` (`Truncate.string(@plan_bytes)`).
  Proved by: no test of the rollback or the timeout (SQLite answers too fast); `explain_test.exs`, "a database error is returned, not raised".
- [ ] Capture in the host process keeps raw params only for a stored whole SELECT, at most 50 scalars and 4 KB of binaries, copying binaries.
  Held by: `capture/3` (`stored != sql`, `select?/1`), `capture_params/1`, `walk/3`, `param/2`, `copy/1`.
  Proved by: `explain_test.exs`, "SQL too long to be stored whole is not explained", "params: up to 50 scalars, 4 KB of binaries in all, arrays counted with their elements", "binaries are copied: a param cut out of a large body does not keep it alive", "big integers and Decimal coefficients count their bytes", "invalid UTF-8 or a multibyte keyword never raise"; `plugins/ecto_test.exs`, "keeps the raw params of a SELECT for EXPLAIN, not of a write".
- [ ] A click explains only a query of the page shown, picked by seq; the raw params are never rendered or exported.
  Held by: the Ecto panel reading the event back from the Store for this page's sids, `EctoExport` (stored redacted string only).
  Proved by: `explain_panel_test.exs`, "a seq of another page is never explained" and "malformed clicks are ignored, never break the tab"; `ecto_export_test.exs`, "full: every captured detail, JSON safe, raw explain params never included".

**Look closely at**
- `separator?/1` quote and comment scanning versus what each database really does with `''`, `\`, `--` and `/* */` (the backslash refusal exists for MySQL): this is the code that decides what reaches the database.
- `first_word/1` looks at 7 bytes and splits on space, tab, newline or `(`: `select?/1` for `WITH`, `SELECT(`, and a statement starting with a comment that `statement/1` skips.
- `explain/3` calls `repo.query!("SET LOCAL statement_timeout = ...")` on Postgres inside the transaction: check a failure there is caught by the `rescue`.
- `capture/3` runs inside every Ecto query of a tracked page: the `walk/3` budget, `:binary.copy/1` of up to 4 KB and `select?/1` on SQL up to 8 KB.

**Try by hand** (`PORT=4001 mix dev`, then ...)
- `http://localhost:4001/` (users page), Ecto tab: each SELECT row has `#pdt-explain-<seq>`. Click it: expect a plan containing `SCAN` or `SEARCH` in `#pdt-plan-<seq>`, and the user rows unchanged afterwards.
- `http://localhost:4001/counter`, click `#fail` (failing query): the failed row has no explain button and its details say "the query itself failed". A write row (for example `#job-one` on `http://localhost:4001/jobs`) has no button and says "only SELECT queries are explained".

## 9. `Suspender` and `Tracer`

Files: `lib/phoenix_dev_toolbar/suspender.ex`, `lib/phoenix_dev_toolbar/tracer.ex` (callers: `process_actions.ex` `suspend/2`, `panels/system.ex` `start_trace/1`). Governing ADRs: [ADR 10](../adr/10-process-addressing-and-actions.md), [ADR 11](../adr/11-system-tab.md). Runs in: their own GenServers (toolbar supervisor children); they act on host pids and are called only from the panel with a 1 s timeout.

**Must hold**
- [ ] At most 10 processes are suspended at once, each for 100 ms to 60 s; the same pid cannot be suspended twice.
  Held by: `Suspender.check/3` (`@max_suspended`, `@min_ttl_ms..@max_ttl_ms`, `Map.has_key?(state.suspended, pid)`).
  Proved by: `suspender_test.exs`, "refuses twice the same, a dead one, a bad TTL, and more than ten".
- [ ] A suspended process is always resumed: at its TTL, when the panel that asked goes away, on Resume, and when the Suspender itself dies.
  Held by: the `handle_info` clauses for `{:expire, pid, token}` and `{:DOWN, ref, :process, _pid, _reason}` (`{:ok, {:owner, pid}}` resumes), `release/3`; OTP drops a dead process's suspensions.
  Proved by: `suspender_test.exs`, "suspends for the TTL, then resumes", "the owner going away resumes what it suspended", "a Suspender crash resumes everything it suspended"; `system_panel_test.exs`, "a panel that dies resumes what it suspended".
- [ ] A Suspender or Tracer that is down or slow answers `{:error, :unavailable}` to the panel; it does not crash or block the panel beyond 1 s.
  Held by: `call/1` in both modules (`GenServer.call(@name, message, @call_timeout)` with `catch` of `:exit, _reason` returning `{:error, :unavailable}`).
  Proved by: no test of the unavailable path; `tracer_test.exs`, "a Tracer crash ends the trace; a new one can start" covers a restart.
- [ ] Only one trace runs on the node, at most 100 messages or 10 s, through a trace session (never the global tracer), and every stop destroys the session.
  Held by: the `handle_call({:start, pid, owner}, ...)` clause (`{true, %{owner: other, running?: true}} when other != owner` replies `{:error, :busy}`), `record/4` (`@max_events`), `@ttl_ms`, `finish/2`, `clear/1`, `destroy/1`, `terminate/2` with `Process.flag(:trap_exit, true)`.
  Proved by: `tracer_test.exs`, "stops by itself at the message limit", "stops by itself when its time is up", "one trace on the node: another panel is told it is busy", "stops when the process exits; Stop keeps what it recorded", "the panel going away clears its trace", "a finished trace still goes with its panel", "a Tracer crash ends the trace; a new one can start".
- [ ] Traced messages are redacted and truncated before they are stored, and queued trace messages are dropped when a trace ends.
  Held by: `record/4` (`Truncate.redact() |> Truncate.inspect_value()`), `drain/0`, the catch all `handle_info({:trace, _pid, _kind, _message}, state)` clauses.
  Proved by: `tracer_test.exs`, "records what the process receives and sends, redacted".
- [ ] Neither process is reachable except through the actions policy and the protected set.
  Held by: `ProcessActions.suspend/2` and `Panels.System.start_trace/1` both call `ProcessActions.allowed/2` first; the modules themselves do not check.
  Proved by: `system_panel_test.exs`, "a protected process offers no trace" (button absence only). No test on a forged event or on suspend of a protected pid.

**Look closely at**
- `Suspender.do_suspend/4`: `:erlang.suspend_process/1` can block the Suspender until the target is suspended; the 1 s caller timeout then reports `:unavailable` while the suspend may still complete later. Compare with the message in `ProcessActions.suspend_error(:unavailable)`.
- `Suspender.release/3` pops `entry` without a nil case: check every caller only passes a pid present in `state.suspended` (`handle_call({:resume, ...})`, `{:expire, ...}` token match, `refs` lookup).
- `Tracer.finish/2` and `clear/1` order of `destroy`, `drain` and `Process.demonitor`: a stop racing with a trace message already in the mailbox.
- `Tracer.handle_call({:start, ...})` with `clear(state)` when the same owner restarts: confirm the old session is destroyed before `session_create`.

**Try by hand** (`PORT=4001 mix dev`, then ...)
- `http://localhost:4001/counter`: open the Process tab, follow the link of the page's LiveView to the System tab. Click `#pdt-system-suspend`, then `#pdt-system-confirm`; click `#click` on the page: no update for about 10 s, then it catches up. Suspend again and reload the page (the panel goes away): the process is resumed at once.
- Same inspected process: click `#pdt-system-trace-start`, click `#click` on the page a few times: `#pdt-system-trace-list` lists received messages with their direction. After 10 s `#pdt-system-trace-status` says it stopped. Open a second browser tab with the panel and start a trace there while the first runs: expect "Another panel is tracing a process".

## 10. `EvalRunner`, `Plugins.Eval` and `Panels.Eval`

Files: `lib/phoenix_dev_toolbar/eval_runner.ex`, `lib/phoenix_dev_toolbar/plugins/eval.ex`, `lib/phoenix_dev_toolbar/panels/eval.ex`. Governing ADR: [ADR 12](../adr/12-cluster-and-eval-plugins.md). Runs in: the panel LiveView component and its `start_async/3` task; typed code runs in a process spawned by `EvalRunner.run/2`; the plugin is not in `:defaults`.

**Must hold**
- [ ] Typed code never runs unless the host sets `allow: :eval`, even for a forged `eval` event.
  Held by: `Panels.Eval` `handle_event("eval", ...)` (branch `{:ok, :read_only}` sets the note "Code does not run here"), `Plugins.Eval` `@defaults %{allow: :read_only, clients: :loopback, timeout_ms: 5000}`.
  Proved by: `eval_test.exs`, "read only by default: queries run, code does not" and "a forged eval event under the default config runs nothing".
- [ ] Code runs only for a browser on this machine unless `clients: :any`, checked on every event and not only at render; a proxied join is not loopback.
  Held by: `Panels.Eval.allowed/1` (`ClientPolicy.loopback?(client)` with `client = (socket.assigns[:pdt_actions] || %{})[:client]`), applied in `handle_event("eval", ...)` and `render/1`.
  Proved by: `eval_test.exs`, "a browser off this machine runs no code, unless clients: :any; queries stay open", "a browser behind a proxy or tunnel is not loopback, even from 127.0.0.1"; `panel_socket_test.exs`, "a direct join is a loopback client; one with X-Forwarded-For is not".
- [ ] An explicit `actions: false` in the host config refuses code even with `allow: :eval`; an unset `actions` does not.
  Held by: `Panels.Eval.allowed/1` (`ClientPolicy.explicitly_off?()`), `ClientPolicy.explicitly_off?/0`.
  Proved by: `eval_test.exs`, "an explicit actions: false refuses code even with allow: :eval; unset does not".
- [ ] Read queries are chosen by id from a fixed list; the browser never supplies code for them.
  Held by: `EvalRunner.query/1` (`List.keymember?(@queries, id, 0)`, `read/1` clauses), `Panels.Eval` `handle_event("query", ...)`.
  Proved by: `eval_test.exs`, "every read query runs and returns a bounded result". No test for an unknown id.
- [ ] Code runs in a process of its own and is killed at the timeout even when the panel that asked is gone; one run at a time, last 10 runs kept.
  Held by: `EvalRunner.run/2` (`spawn_monitor`, then `after timeout_ms ->` followed by `Process.exit(pid, :kill)`), `watchdog/2` (`timeout_ms + 50`), `Panels.Eval.start/3` (`running?: true`), `@history`.
  Proved by: `eval_test.exs`, "code is stopped on time even when its caller is gone", "with allow: :eval, code runs: result, output, errors and a timeout". No test for the one run at a time rule.
- [ ] Code size, printed output and result are bounded: 10 000 bytes of code, 8 000 bytes of output (dropped while it runs), truncated result and error text.
  Held by: `eval/2` (`byte_size(code) > @max_code_bytes`), `capped_io/2`, `keep/3`, `inspect_result/1`, `Truncate.string(text, @output_bytes)`.
  Proved by: `eval_test.exs`, "code is capped in size" and "what code prints is capped while it runs".
- [ ] Overrides are warned about at boot, options are validated (a bad option disables the plugin, not the host), and each run is logged with its size, never its code.
  Held by: `Plugins.Eval.init/1`, `validate/1`, `warn_overrides/1`; `EvalRunner.eval/2` (`Logger.info` with `byte_size(code)` only).
  Proved by: `eval_test.exs`, "safe defaults; each override is validated and warned about". No test that the code text is absent from the log.

**Look closely at**
- `Panels.Eval.allowed/1`: the `case` over `{explicitly_off?, clients, loopback?}`; with `clients: :any` the only remaining barriers are the Host check, the Origin rule and the sid held in the signed session.
- `handle_event("eval", ...)` caps the stored draft with `cap/2` but passes the raw `code` to `EvalRunner.eval/2`: the size limit lives in `eval/2`.
- `EvalRunner.evaluate/1`: `Code.eval_string/3` in a process whose group leader is the capped IO server, and `io_request/3` calling `apply(module, fun, args)` for `{:put_chars, _, module, fun, args}` inside the IO server process.
- `watchdog/2` is an unlinked `spawn`: confirm it exits when the evaluator ends on its own.

**Try by hand** (`PORT=4001 mix dev`, then ...)
- The harness has `{PhoenixDevToolbar.Plugins.Eval, allow: :eval}` and `actions: :loopback`. Open any page, tab `#pdt-tab-eval`: `1 + 1` in `#pdt-eval-code` with `#pdt-eval-run` shows `2` in `#pdt-eval-run-0`; `Process.sleep(:infinity)` shows "No result after 5000 ms: stopped." and the log shows one `evaluating N bytes` line without the code.
- In `dev.exs` change `{PhoenixDevToolbar.Plugins.Eval, allow: :eval}` to `PhoenixDevToolbar.Plugins.Eval`, restart: `#pdt-eval-form` is gone and `#pdt-eval-read-only` is shown. Restore it, then change `:actions, :loopback` to `false`: expect `#pdt-eval-disabled` and no `#pdt-eval-form`.

## 11. `assets/js/loader.js` and `assets/js/panel.js`

Files: `assets/js/loader.js` (bundled to `priv/static/loader.js`), `assets/js/panel.js` (bundled to `priv/static/panel.js`), helpers `client_events.mjs`, `layout.mjs`, `reloads.mjs`. Governing ADR: [ADR 04](../adr/04-ui-delivery.md). Runs in: the browser, the loader in the host page's top window, the panel in the toolbar's iframe.

**Must hold**
- [ ] The loader runs only in the top window and once per page.
  Held by: the final block of `loader.js` (`window.top === window && !window.__phoenixDevToolbar`).
  Proved by: no test (browser only).
- [ ] Everything the loader draws lives in the open shadow root of one `div#phoenix-dev-toolbar`, so host CSS and toolbar CSS cannot meet.
  Held by: `mount()` (`host.attachShadow({mode: "open"})`, `root.append(style, frame, handle, pill)`, inline `host.style.cssText`).
  Proved by: no test (browser only).
- [ ] Messages are accepted in both directions only when `event.origin` is the page's origin and `event.source` is the expected window; outgoing messages name the page's origin as target.
  Held by: `loader.js` message listener (`event.origin !== window.location.origin || event.source !== frame.contentWindow`), `post()` (`window.location.origin`); `panel.js` listener (`event.source !== window.parent`), `toParent()`.
  Proved by: no test (browser only).
- [ ] The loader acts on a closed set of message types with validated payloads (`pdt:dock` only for a known dock, `pdt:reserve` only for a boolean).
  Held by: the chain of `type === "pdt:toggle"`, `"pdt:open"`, `"pdt:dock"`, `"pdt:reserve"` tests in the loader's message listener (`DOCKS.includes(event.data.dock)`, `typeof event.data.reserve === "boolean"`); stored layouts go through `parseLayout`.
  Proved by: `assets/js/test/layout.test.mjs`, "missing, garbled or unknown layouts fall back to the default" (storage parsing only).
- [ ] Every `localStorage` and `sessionStorage` access is wrapped in `try/catch`; blocked storage degrades to defaults and never throws.
  Held by: loader `readState`, `writeState`, `readLayout`, `writeLayout`; panel `storage()`, `pruneLoads`, `recordLoad`, `forgetLoads`.
  Proved by: `assets/js/test/reloads.test.mjs`, "a stored list that is not one counts as empty" (parsing only); wrapping itself is untested.
- [ ] The listeners the loader adds to the host page are passive, never throw into host dispatch, copy only whitelisted scalar fields and are rate limited and buffered.
  Held by: `EVENTS.forEach` with `{passive: true}` and a `try/catch` in the handler, `sanitize`, `createLimiter(PER_SECOND)`, `createQueue(BUFFER, ...)` (`createQueue` in `client_events.mjs`).
  Proved by: `assets/js/test/client_events.test.mjs`, "listens to LiveView's fixed window events only", "sanitize never runs host getters", "sanitize survives a throwing or revoked Proxy", "the limiter allows N per second and counts the rest", "the queue buffers until ready, bounded, then sends in order".
- [ ] The only host DOM writes are the toolbar's `div` and, for side docks, inline padding on `<html>` that is restored afterwards.
  Held by: `createSidePadding()` (stores `original`, `restore(prop)`), `placeHost()`.
  Proved by: no test (browser only).

**Look closely at**
- The bottom of `loader.js` sets `window.__phoenixDevToolbar = true`: compare it with "no host globals" in ADR 04 and AGENTS.md. Also `grep -n liveSocket assets/js/loader.js` to confirm it never touches `window.liveSocket`.
- `mount()` builds `frame.src` from `script.dataset.pdtPath` and `encodeURIComponent(sid)`: both come from the tag the plug wrote and escaped.
- `panel.js` posts `toParent("dock", ...)` and `toParent("reserve", ...)` from click targets inside server rendered HTML: check what a plugin's panel HTML could put in `data-pdt-*` attributes.
- `priv/static/loader.js` and `panel.js` are committed bundles: confirm they match the sources (`mix assets.build` then `git diff --exit-code priv/static`, which CI does).

**Try by hand** (`PORT=4001 mix dev`, then ...)
- Isolation, in the console of `http://localhost:4001/counter`: `document.querySelector('#phoenix-dev-toolbar').shadowRoot.querySelector('iframe').src` ends with `/__pdt/panel?sid=...`; `document.getElementById('pdt-panel')` is `null`; `Object.keys(window).filter(k => /pdt|phoenixdev/i.test(k))` lists what the loader added to `window`. Then `document.head.append(Object.assign(document.createElement('style'), {textContent: 'iframe{display:none!important}'}))`: the toolbar stays visible.
- Source check: `window.postMessage({type: 'pdt:hide'}, location.origin)` in the console: the toolbar must not hide (the source is the page, not the iframe). Clicking `#pdt-hide` inside the panel does hide it, and the pill returns it.
- Blocked storage: in Chrome, `chrome://settings/cookies` then "Block all cookies", reload the page: the toolbar still appears collapsed and the console shows no error from `loader.js` or `panel.js`. Restore the setting afterwards.

## After the review

When every box above is ticked and every failed box has an issue that is closed or consciously deferred, the README disclaimer ("fully AI-coded and has not been reviewed by a human") can be replaced by a factual note such as: "AI-assisted: the modules that run in your processes or gate access were reviewed by a human, see the review checklist". That edit is the owner's to make.
