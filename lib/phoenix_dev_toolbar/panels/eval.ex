defmodule PhoenixDevToolbar.Panels.Eval do
  @moduledoc false
  # The Eval tab (ADR 12). Read queries, picked by id, answer any browser, like
  # the System tab's reads (ADR 10). Typed code (EvalRunner) runs only with
  # `allow: :eval`, and only for a browser on this machine unless the host set
  # `clients: :any` (the panel's websocket peer, from the internal `pdt_actions`
  # assign). Both in start_async/3: one run at a time, the last @history kept.
  # A forged event is checked like a click.

  use PhoenixDevToolbar.Panel

  alias PhoenixDevToolbar.ClientPolicy
  alias PhoenixDevToolbar.EvalRunner
  alias PhoenixDevToolbar.Panel
  alias PhoenixDevToolbar.Plugins

  @history 10

  @impl Phoenix.LiveComponent
  def mount(socket),
    do: {:ok, assign(socket, runs: [], running?: false, code: "", query: "memory", note: nil)}

  @impl Panel
  def handle_reset(_events, socket), do: socket

  @impl Panel
  def handle_events(_events, socket), do: socket

  @impl Phoenix.LiveComponent
  def handle_event("pick", %{"query" => id}, socket) when is_binary(id),
    do: {:noreply, pick(socket, id)}

  def handle_event("query", %{"query" => id}, socket) when is_binary(id) do
    socket = pick(socket, id)

    case List.keymember?(EvalRunner.queries(), id, 0) do
      true -> {:noreply, start(socket, label(id), fn -> EvalRunner.query(id) end)}
      false -> {:noreply, socket}
    end
  end

  # The draft is kept across renders (and capped, the textarea's maxlength is
  # client side only).
  def handle_event("draft", %{"code" => code}, socket) when is_binary(code),
    do: {:noreply, assign(socket, :code, cap(code, EvalRunner.max_code_bytes()))}

  def handle_event("eval", %{"code" => code}, socket) when is_binary(code) do
    %{allow: allow, timeout_ms: timeout_ms} = config(socket)

    case {allowed(socket), allow} do
      {:ok, :eval} ->
        {:noreply,
         socket
         |> assign(:code, cap(code, EvalRunner.max_code_bytes()))
         |> start(preview(code), fn -> EvalRunner.eval(code, timeout_ms) end)}

      {:ok, :read_only} ->
        {:noreply, assign(socket, :note, "Code does not run here: allow: :eval is not set.")}

      {{:error, _why}, _allow} ->
        {:noreply, socket}
    end
  end

  def handle_event("clear", _params, socket), do: {:noreply, assign(socket, runs: [], note: nil)}
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveComponent
  def handle_async(:run, {:ok, {label, {:ok, run}}}, socket),
    do: {:noreply, socket |> assign(:running?, false) |> push_run(Map.put(run, :label, label))}

  def handle_async(:run, {:ok, {_label, {:error, why}}}, socket),
    do: {:noreply, assign(socket, running?: false, note: why)}

  def handle_async(:run, _other, socket), do: {:noreply, assign(socket, :running?, false)}

  defp pick(socket, id) do
    case List.keymember?(EvalRunner.queries(), id, 0) do
      true -> assign(socket, :query, id)
      false -> socket
    end
  end

  defp start(%{assigns: %{running?: true}} = socket, _label, _fun), do: socket

  defp start(socket, label, fun) do
    socket
    |> assign(running?: true, note: nil)
    |> start_async(:run, fn -> {label, fun.()} end)
  end

  defp push_run(socket, run),
    do: assign(socket, :runs, Enum.take([run | socket.assigns.runs], @history))

  defp config(socket), do: Plugins.Eval.config(socket.assigns[:config])

  # A browser on this machine, unless the host opened the tab to any. An explicit
  # `actions: false` in the host config refuses code altogether; an unset
  # `actions` (also off for kill and suspend) does not: Eval has its own opt-in.
  defp allowed(socket) do
    actions = socket.assigns[:pdt_actions] || %{}

    case actions do
      # Computed once per panel mount (PanelLive): no interface lookup per render.
      %{local?: local?} -> decide(config(socket).clients, local?)
      _no_verdict -> gate(actions[:client], config(socket).clients)
    end
  end

  @doc false
  @spec gate(
          :inet.ip_address() | nil,
          :local | :loopback | :any,
          (-> [:inet.ip_address()])
        ) :: :ok | {:error, :disabled | :not_local}
  def gate(client, clients, own_addresses \\ &PhoenixDevToolbar.ClientMatch.own_addresses/0) do
    case {ClientPolicy.explicitly_off?(), clients} do
      {true, _clients} -> {:error, :disabled}
      {false, :any} -> :ok
      {false, clients} -> decide(clients, ClientPolicy.local?(client, own_addresses))
    end
  end

  defp decide(clients, local?) do
    case {ClientPolicy.explicitly_off?(), clients, local?} do
      {true, _clients, _local?} -> {:error, :disabled}
      {false, :any, _local?} -> :ok
      {false, _local, true} -> :ok
      {false, _local, false} -> {:error, :not_local}
    end
  end

  defp label(id), do: id |> then(&List.keyfind(EvalRunner.queries(), &1, 0)) |> elem(1)

  defp preview(code), do: code |> String.trim() |> cap(200)

  defp cap(text, bytes) when byte_size(text) <= bytes, do: text
  defp cap(text, bytes), do: PhoenixDevToolbar.Truncate.string(text, bytes)

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assign(assigns,
        gate: allowed(%{assigns: assigns}),
        allow: config(%{assigns: assigns}).allow
      )

    ~H"""
    <div id="pdt-eval" class="pdt-process">
      <p
        :if={@allow == :eval and @gate == {:error, :disabled}}
        id="pdt-eval-disabled"
        class="pdt-hint pdt-process__paused"
      >
        Code is off: the host config sets actions: false. Remove it, or set actions: :local.
      </p>
      <p
        :if={@allow == :eval and @gate == {:error, :not_local}}
        id="pdt-eval-off"
        class="pdt-hint pdt-process__paused"
      >
        Code only runs for a browser on this machine (loopback or its own addresses), reaching the server directly (not
        through a proxy that adds X-Forwarded-* headers). From Docker or another machine, an
        SSH tunnel to localhost keeps it that way; clients: :any in the Eval options lets anyone who
        reaches the dev server run code here.
      </p>
      <div class="pdt-snapshot-bar">
        <form
          id="pdt-eval-query-form"
          class="pdt-actions__kill"
          phx-change="pick"
          phx-submit="query"
          phx-target={@myself}
        >
          <select id="pdt-eval-query" name="query" aria-label="Read query">
            <option :for={{id, label} <- EvalRunner.queries()} value={id} selected={id == @query}>
              {label}
            </option>
          </select>
          <button id="pdt-eval-query-run" type="submit" class="pdt-button pdt-button--small">
            Read
          </button>
        </form>
        <button
          :if={@runs != []}
          id="pdt-eval-clear"
          type="button"
          class="pdt-button pdt-button--small"
          phx-click="clear"
          phx-target={@myself}
        >
          Clear
        </button>
      </div>
      <form
        :if={@gate == :ok and @allow == :eval}
        id="pdt-eval-form"
        class="pdt-eval__form"
        phx-change="draft"
        phx-submit="eval"
        phx-target={@myself}
      >
        <label for="pdt-eval-code" class="pdt-hint">
          Elixir, evaluated on this node (stopped after its timeout)
        </label>
        <textarea
          id="pdt-eval-code"
          name="code"
          rows="4"
          maxlength={EvalRunner.max_code_bytes()}
          spellcheck="false"
          autocomplete="off"
        >{@code}</textarea>
        <button
          id="pdt-eval-run"
          type="submit"
          class="pdt-button pdt-button--small"
          aria-busy={to_string(@running?)}
        >
          {if(@running?, do: "running…", else: "Run")}
        </button>
      </form>
      <p
        :if={@gate == :ok and @allow == :read_only}
        id="pdt-eval-read-only"
        class="pdt-hint pdt-process__paused"
      >
        Read only: set allow: :eval in the Eval plugin's options to run code.
      </p>
      <p :if={@note} id="pdt-eval-note" class="pdt-hint pdt-process__paused" role="status">{@note}</p>
      <ol id="pdt-eval-runs" class="pdt-list">
        <li
          :for={{run, index} <- Enum.with_index(@runs)}
          id={"pdt-eval-run-#{index}"}
          class="pdt-eval__run"
        >
          <div class="pdt-row__head">
            <code>{run.label}</code>
            <span class="pdt-time">{run.ms} ms</span>
          </div>
          <pre :if={run.output != ""} class="pdt-eval__output" data-pdt-eval="output">{run.output}</pre>
          <pre :if={run.result} class="pdt-eval__result" data-pdt-eval="result">{run.result}</pre>
          <pre :if={run.error} class="pdt-error" data-pdt-eval="error">{run.error}</pre>
        </li>
      </ol>
    </div>
    """
  end
end
