This is an open source Elixir library: `phoenix_dev_toolbar` (`PhoenixDevToolbar`), a dev-only, BEAM-native debug toolbar for Phoenix LiveView applications. It is installed by other people into their apps, so it must be invisible in production and cheap in development. Start from [ADR 00](./adr/00-vision-and-scope.md) and the [roadmap](./docs/2026-11-05-roadmap.md).

## Our interactions

- When you answer:
  - Keep each response concise, complete, and easy to understand
  - Remove information that does not help the user
  - Let the completed work show the result
  - Include strictly necessary context in your response
  - Don't restate things you already said in the same answer

## Tooling

- `mix dev` boots the single-file dev harness (`dev.exs`, a tiny Phoenix app with LiveViews and a SQLite repo) at `http://localhost:4000` with the toolbar mounted. Use it to check every UI change by hand, in a real browser. See [ADR 06](./adr/06-dev-harness-and-testing.md)
  - If port 4000 is taken (most likely by me), run with `PORT=4001 mix dev`
- After changing `assets/`, run `mix assets.build` and commit `priv/static` (CI fails on stale bundles)
- `mix precommit` is the quality gate (see Project guidelines)
- `agent-tools/ci-min.sh` replays the minimum CI row (Elixir 1.17, OTP 26, LiveView `~> 1.1.0`) in Docker on a copy of the working tree. `mix precommit` only runs on the local toolchain: run it before pushing changes to tests, LiveView internals or OTP-version-dependent code (the Tracer)
- Releasing (the owner runs it): `mix bump [--version patch|minor|major]` runs `mix precommit` and `agent-tools/ci-min.sh`, sets the version (an untagged version, like the first 0.0.1, is released as is), moves the CHANGELOG `[Unreleased]` entries into the dated release section, commits and tags `<version>` (plain, as on Hex) without pushing; `./publish.sh` pushes, waits for CI and runs `mix hex.publish` (`--dry-run` first). The task lives in `tooling/`, compiled in dev and test only and never shipped: a `Mix.Tasks.*` module in `lib/` would land in every host app and clash with its own tasks
- You can create your own tooling to optimize your workflows (put scripts under `agent-tools/`). However, ask for review from me.

## Subagent workflow and token budget

Post-hoc review and remediation used to cost 3 to 7 times the feature build itself. These rules keep multi-agent work cheap:

- **Review left, not after**: every spec includes a short "Risks" section covering the final-review dimensions (hot path cost of telemetry handlers, production footprint, memory bounds, host app conflicts (CSS, JS, CSP, LiveSocket), public API and docs, tests and ADR sync). Implementers address it while building
- **One combined reviewer, only where it matters**: do not dispatch a spec reviewer plus a quality reviewer per task. Use a single combined reviewer, only for risky tasks (telemetry handlers, ETS storage, HTML injection, anything running inside the host's processes, public behaviours). Low-risk tasks are covered by the final review
- **Triage findings before fixing**: classify review findings as must-fix (prod leakage, host crash, unbounded memory), batch (small fixes grouped into one agent) or defer (noted as an ADR limitation). Never spawn one agent per finding by default
- **Small subagent tasks**: aim for under ~40 turns per agent. The plan gives each agent the exact files and line ranges it needs so it does not explore. A task that needs more is two tasks
- **Targeted reads**: read the relevant line ranges or `grep -n` first; avoid paging through large modules. For Phoenix/LiveView internals read the source in `deps/` instead of guessing
- **Verify per batch, not per task**: subagents run only affected tests (`mix test <files>`, plus `mix compile --warnings-as-errors`). The orchestrator runs `mix precommit` once on the merged result before declaring done
- **Survive usage-limit pauses**: subagents commit at milestones and keep a short handoff note (done, next, open questions) in the scratchpad, so a resume reads the note instead of replaying history

## Project guidelines

- Use the `adr` folder for product and architectural decisions. Start from the index in [adr/README.md](./adr/README.md). Always update the ADRs related to the feature you implemented, following these rules:
  - An ADR states the **current** decision. When behavior changes, edit the decision in place. Delivery notes, phase logs and review-fix logs go in commits and `CHANGELOG.md`, never appended to the ADR: git keeps the history
  - A decision that replaces another gets a new ADR. The old one keeps its file and number and gets `**Status:** Superseded by [ADR N](...)`
  - New ADRs copy [adr/TEMPLATE.md](./adr/TEMPLATE.md) (Status / Area / Related header), take the next free number and get a row in `adr/README.md`. Numbers are permanent and unique; code cites ADRs as `ADR N`
  - Soft cap of about 500 lines per ADR: past it, split by subtopic
- Plans live in `docs/` as dated files (`docs/YYYY-MM-DD-<topic>-plan.md`), one per phase or feature batch, each with a "Risks" section. The roadmap is [docs/2026-11-05-roadmap.md](./docs/2026-11-05-roadmap.md): tick phases there when they land
- `CHANGELOG.md` is a short reminder for me, not release notes: one line per feature or fix (under ~100 chars), a noun phrase plus the ADR number, no explanations of behavior (those live in the ADR and commits). Group related fixes into one line; a feature batch adds 5 to 10 lines at most
- Media (screenshots, GIFs) lives in `media/` and never reaches a host app's install: `media/` stays out of the Hex `package` `files` (`mix.exs`), the README links it with relative `media/...` paths, and ExDoc's `assets` option (`mix.exs`) copies it into the docs so hexdocs renders each version's own images
  - When building a user-visible feature, decide whether it deserves a screenshot: a new tab or view, or behavior a reader cannot picture from text. When changing a feature that has media, retake it in the same batch
  - Capture from `mix dev` at 1440x900, toolbar docked at the bottom (unless the shot is about docks or collapse), harness fixture data only. Keep PNGs under ~300 KB and GIFs under ~5 MB; videos for posts stay out of the repo
- Always use `mix precommit` alias when you are done with all changes and fix any pending issues
  - Alternatively use `mix compile --warnings-as-errors`, `mix test`, `mix credo --strict`, `mix dialyzer` and `mix docs --warnings-as-errors`
  - Never report `mix precommit` as passing unless the command fully completed with exit code 0
  - For mix precommit, confirm all checkpoints before declaring success:
    - test summary line (N tests, 0 failures)
    - Credo summary (found no issues)
    - Dialyzer completion without errors (Total errors: 0 or equivalent success)
    - ExDoc generated docs without warnings
  - A non-zero exit with every checkpoint green is a real failure: read the lines after the last section (for example `ERROR! Test suite aborted ... due to warnings while using the --warnings-as-errors option` means a compile warning in a test file)
- Tests are first class citizen and should be often write before implementation. Use the `test-desiderata` skill if available or Kent Beck's test desiderata
  - NEVER assume failing tests were pre-existing unless I tell you
  - If a command times out, explicitly state "still running/unfinished" and continue from terminal output until completion. Do not infer success from partial logs
- Start your answer with a random emoji, so I know you've read those instructions
- Never use `git add -A` for slice commits unless user explicitly asks for a bulk commit. Stage only intended files for the slice
- Avoid big chained shell commands with multiline commit messages (can get stuck in quote prompts). Use short single commands per step or `git commit -F <tempfile>`
- Before any commit, run `git status --short` and explicitly decide what to do with untracked files; do not accidentally absorb them into unrelated slices
- Don't use hypens ("—") when creating content. Prefer ":" or other solutions that fit the content
- This is a public repository: never write the maintainer's personal information (name, email, local paths, machine names) or the names of other projects, apps or clients outside this one into code, tests, comments, docs, ADRs, plans, CHANGELOG or commit messages. Use the fixtures (`dev.exs`, `fixtures/host_app`, `Demo*` modules) or generic wording ("a host app", "an agent") instead. The only exceptions are the license holder in `LICENSE` and the project's own repository URL

### Library guidelines

This code runs inside other people's applications. These rules are not negotiable:

- **Zero production footprint** ([ADR 01](./adr/01-zero-prod-footprint-and-installation.md)): every entry point (plug, telemetry attach, supervisor children) is a no-op unless `PhoenixDevToolbar.enabled?/0`. The only host-facing entry point is `PhoenixDevToolbar.Plug` inside the endpoint's `if code_reloading?` block, with the dep declared `only: :dev`. **Never** add an integration that needs host code outside that block (a router macro, an `import`): it breaks prod compilation, see `fixtures/host_app`
- **Hot path rule** ([ADR 02](./adr/02-telemetry-collection-and-correlation.md)): telemetry handlers run inside the host's processes (request, LiveView, Repo caller). For an untracked process they do two `Process.get/1` (`:pdt_sid`, then `:"$callers"`) plus one ETS lookup per caller pid, and return; only `[:phoenix, :live_view, :mount, :start]` always reaches `Tracker` first. They **never** raise (wrap the body in `try/rescue` and log once: `:telemetry` detaches a handler that raises), **never** call a GenServer synchronously, **never** do I/O
- **Everything is bounded** ([ADR 03](./adr/03-event-storage.md)): every buffer has a cap and a TTL, every payload is truncated before storage (`inspect/2` limits), no unbounded lists in LiveView assigns (use streams), **never** create atoms from runtime input
- **Optional dependencies stay optional**: `ecto_sql` (and any future integration like Oban or Ash) is `optional: true` and only touched behind `Code.ensure_loaded?/1`. Never add a required dependency without an ADR. Prefer OTP and stdlib primitives (ETS, `:atomics`, `Registry`, `:telemetry`) over external packages
- **Host isolation** ([ADR 04](./adr/04-ui-delivery.md)): the toolbar never leaks CSS or JS into the host page (two exceptions, ADR 04: the side-dock `<html>` padding and the opt-in `_pdt_label` cookie, dev only, set only on `?pdt_label=`) and never requires changes to the host `app.js`. The injected loader is read-only towards `window.liveSocket` and feature-detects everything it touches
- **Depend on public surfaces**: use telemetry events, `Phoenix.LiveView.Debug` and documented APIs. If something forces reading LiveView private fields, isolate it in one module, cite the LiveView version, and cover it in the CI version matrix
- **Public API is documented**: every public module has `@moduledoc`, every public function `@doc` and `@spec`; internal modules are `@moduledoc false`. Behaviours ship with a working example. Breaking a public API needs a CHANGELOG line (while on 0.0.x every release may break; from 0.1 on, a minor version bump)
- Metrics we emit about ourselves (dropped events, store size) should be low cardinality

<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option
- Write `@spec` and `@doc` for public functions
- Avoid to use `any()` or `map()` typespecs when possible. Try to leverage the type system and dialyzer to catch typing errors early
  - Prefer structs to map when possible, and serialize/deserialize to the database if needed
- When helper return shapes are specialized (example: :ok | {:unauthorized, socket}), do not keep impossible {:error, _} branches in callers

### Personal Elixir/Phoenix/Ecto Guidelines

- **Don't** use `__MODULE__` to refer to the current module unless necessary, use the module name directly (use `alias __MODULE__`)
- **Avoid** `if` usage when possible. Prefer pattern matching and/or `maybe_` functions
  - **Avoid** negated conditions in if/else blocks

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Reuse shared test helpers before writing local ones**: check `test/support` first; a helper copied into a third file belongs in `test/support`
- **JS changes get JS tests** ([ADR 06](./adr/06-dev-harness-and-testing.md)): pure helpers go in `assets/js/*.mjs` with unit tests; `loader.js`/`panel.js` wiring is tested at DOM level on the fake DOM in `assets/js/test/support/fake_dom.mjs` (extend it rather than adding npm dependencies). `mix test.js` runs them, Node built-ins only
- Telemetry tests attach with a unique handler id per test and detach in `on_exit/1`; ETS assertions read through the public `Store` API, not the raw table

- **Always** write tests when you implement a new feature or page
  - LiveView tests should be implemented to test an entire workflow of a page, using the helpers desctibed at [LiveView Testing](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveViewTest.html). For those tests it is accepted they may sometimes be `sync` (but it's better if they're async in a sandboxed users/environment)
- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @streams.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView form events

- **`phx-change` and `phx-submit` on `<input>` and `<select>` elements REQUIRE the element to be inside a `<form>` tag.** Placing these bindings on bare inputs without a parent `<form>` causes the JS error "form events require the input to be inside a form". Always wrap such inputs:

      <form phx-change="search" phx-submit="search" id="my-search-form">
        <input type="text" name="q" phx-debounce="300" />
      </form>

  Put `phx-change`/`phx-submit` on the `<form>`, not on the `<input>`. The input only needs `name` and optionally `phx-debounce`.

- **Always** give every `<form>`/`<.form>` that uses `phx-change` and/or `phx-submit` an explicit, unique `id` attribute. Without it, LiveView cannot perform form recovery after a crash/reconnect, and `Phoenix.LiveViewTest` emits a "missing id" warning on every render. For a form rendered once per item in a loop, interpolate a unique key into the id, e.g. `id={"save-notes-form-#{entry.id}"}`.

### LiveView JavaScript interop

> In this library, hooks live in `assets/js/panel.js` and are registered on the panel's own `LiveSocket` (ADR 04). Never ask the host to change its `app.js` or register hooks, and do not use colocated hooks. The guidance below is the general Phoenix reference

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- LiveView async patch test rule: for tests relying on assert_patch/2 after submit where a component does send(self(), ...), call render(view) before assert_patch/2 to flush mailbox/handle_info
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->
