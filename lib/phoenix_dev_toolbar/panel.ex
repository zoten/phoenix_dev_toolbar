defmodule PhoenixDevToolbar.Panel do
  @moduledoc """
  A plugin's tab in the toolbar panel: a `Phoenix.LiveComponent` (ADR 05).

  A plugin returns its panel module from `c:PhoenixDevToolbar.Plugin.panel/0`.
  The toolbar renders it inside its own iframe, never in the host page, and
  hands it the plugin's events as they arrive:

      defmodule MyApp.Toolbar.JobsPanel do
        use PhoenixDevToolbar.Panel

        # Events have no :id field: give streams a DOM id from the unique seq.
        @impl Phoenix.LiveComponent
        def mount(socket), do: {:ok, stream_configure(socket, :jobs, dom_id: &"jobs-\#{&1.seq}")}

        @impl PhoenixDevToolbar.Panel
        def handle_reset(events, socket),
          do: stream(socket, :jobs, events, reset: true, limit: -500)

        @impl PhoenixDevToolbar.Panel
        def handle_events(events, socket),
          do: Enum.reduce(events, socket, &stream_insert(&2, :jobs, &1, limit: -500))

        @impl Phoenix.LiveComponent
        def render(assigns) do
          ~H\"\"\"
          <ul id="jobs" class="pdt-list" phx-update="stream">
            <li id="jobs-empty" class="pdt-list__empty">No jobs yet.</li>
            <li :for={{id, job} <- @streams.jobs} id={id} class="pdt-row">{job.data.worker}</li>
          </ul>
          \"\"\"
        end
      end

  Events are the plugin's own, oldest first. Keep them in streams, never in
  plain assigns: a page can produce thousands. `handle_reset/2` gets every
  stored event of a new page (the panel opened, live navigation), and runs
  once with `[]` before the first render; `handle_events/2` gets the new ones
  since. DOM ids must be unique in the whole panel: prefix them with your
  plugin's name and use the event's `seq`.

  The toolbar assigns, before calling either callback:

    * `@config`: the plugin's config, as returned by its `init/1`
    * `@page`: the page shown (`@page.root` is the sid of its HTTP request)
    * `@shown?`: the tab is selected
    * `@visible?`: the panel is open and the browser tab visible

  `c:handle_props/1` runs when only those change, for example to start or stop
  polling. A panel can use every LiveComponent feature except `update/2` and
  `update_many/1`, which the toolbar defines: `handle_event/3`
  (with `phx-target={@myself}`), `start_async/3` and `handle_async/3`. For
  timers, `send_after/4` delivers a message to `c:handle_info/2`. Style it with the panel's `pdt-`
  classes (`pdt-list`, `pdt-row`, `pdt-tag`, `pdt-badge`): the panel
  stylesheet is the only one loaded.

  This behaviour is unstable before 1.0: changes are listed in the CHANGELOG.
  """

  require Logger

  import Phoenix.Component, only: [sigil_H: 2]

  alias Phoenix.LiveView.Socket
  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.LiveViewCompat
  alias PhoenixDevToolbar.Panel
  alias PhoenixDevToolbar.Truncate

  @doc "The page changed: replace everything shown with `events`."
  @callback handle_reset(events :: [Event.t()], Socket.t()) :: Socket.t()

  @doc "New events of the plugin since the last call, oldest first."
  @callback handle_events(events :: [Event.t()], Socket.t()) :: Socket.t()

  @doc "`@shown?`, `@visible?` or `@page` changed. Defaults to doing nothing."
  @callback handle_props(Socket.t()) :: Socket.t()

  @doc """
  A message scheduled with `send_after/4`, or `{:navigate, params}` from
  `navigate/3`. Defaults to ignoring it.
  """
  @callback handle_info(message :: term(), Socket.t()) :: Socket.t()

  @optional_callbacks handle_props: 1, handle_info: 2

  @doc """
  Delivers `message` to the panel `module` with DOM id `id` (its
  `@id`) after `ms` milliseconds, through `c:handle_info/2`. Returns the
  timer reference. Call it from the panel's own callbacks.
  """
  @spec send_after(module(), String.t(), term(), non_neg_integer()) :: reference()
  def send_after(module, id, message, ms),
    do: Phoenix.LiveView.send_update_after(self(), module, %{id: id, pdt: {:info, message}}, ms)

  @doc """
  Switches the panel to the tab of the plugin `plugin_id` and delivers
  `{:navigate, params}` to that tab's `c:handle_info/2`. Returns `socket`
  unchanged, for pipelines. Call it from the panel's own callbacks.

  Use it to link to another tab, for example to inspect a process in the System
  tab. Keep `params` small (a few strings): they go through the panel process
  as they are. A plugin that is not attached or has no tab is ignored, and so is
  a call from anything but a toolbar panel (a host LiveView's socket).

      def handle_event("inspect", %{"pid" => pid}, socket),
        do: {:noreply, Panel.navigate(socket, :system, %{"pid" => pid})}
  """
  @spec navigate(Socket.t(), atom(), map()) :: Socket.t()
  def navigate(%Socket{view: PhoenixDevToolbar.PanelLive} = socket, plugin_id, params)
      when is_atom(plugin_id) and is_map(params) do
    send(self(), {:pdt_navigate, Atom.to_string(plugin_id), params})
    socket
  end

  def navigate(%Socket{} = socket, _plugin_id, _params), do: socket

  @doc """
  Formats a duration in microseconds (`Event.duration`) the way the toolbar
  does: `"0.04 ms"`, `"12.3 ms"`, `"2.50 s"`, `"n/a"` for nil.
  """
  @spec duration(non_neg_integer() | nil) :: String.t()
  defdelegate duration(us), to: PhoenixDevToolbar.Components

  @doc false
  # Used by the toolbar to deliver a message to a panel right away.
  @spec send_now(pid(), module(), String.t(), term()) :: :ok
  def send_now(pid, module, id, message),
    do: Phoenix.LiveView.send_update(pid, module, %{id: id, pdt: {:info, message}})

  @doc false
  defmacro __using__(_opts) do
    quote do
      use Phoenix.LiveComponent

      @behaviour PhoenixDevToolbar.Panel

      @impl PhoenixDevToolbar.Panel
      def handle_props(socket), do: socket

      @impl PhoenixDevToolbar.Panel
      def handle_info(_message, socket), do: socket

      defoverridable handle_props: 1, handle_info: 2

      @before_compile PhoenixDevToolbar.Panel
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    for fun <- [update: 2, update_many: 1], Module.defines?(env.module, fun) do
      {name, arity} = fun

      raise CompileError,
        file: env.file,
        description:
          "#{inspect(env.module)}: a PhoenixDevToolbar.Panel cannot define #{name}/#{arity}"
    end

    # The plugin's own callbacks run behind a boundary: an exception breaks
    # this tab only (the toolbar shows it with a Re-enable button), never the
    # whole panel. A broken tab renders nothing of the plugin's.
    quote do
      @impl Phoenix.LiveComponent
      def update(assigns, socket),
        do: PhoenixDevToolbar.Panel.__update__(__MODULE__, assigns, socket)

      defoverridable render: 1

      @impl Phoenix.LiveComponent
      def render(%{pdt_error: banner} = assigns) when is_binary(banner),
        do: PhoenixDevToolbar.Panel.__broken__(assigns)

      # Code before the template (assign/3, helpers) runs here: guarded too.
      def render(assigns),
        do: PhoenixDevToolbar.Panel.__checked__(fn -> super(assigns) end, assigns)

      unquote(guarded_mount(env))
      unquote(guarded(env, :handle_event, 3))
      unquote(guarded(env, :handle_async, 3))
    end
  end

  # mount/1 runs inside the toolbar's render (LiveView mounts components while
  # diffing): unguarded, a raise would take the whole panel down.
  defp guarded_mount(env) do
    if Module.defines?(env.module, {:mount, 1}) do
      quote do
        defoverridable mount: 1

        @impl Phoenix.LiveComponent
        def mount(socket) do
          super(socket)
        catch
          kind, reason ->
            {:ok, PhoenixDevToolbar.Panel.__break__(socket, kind, reason, __STACKTRACE__)}
        end
      end
    end
  end

  defp guarded(env, name, 3) do
    if Module.defines?(env.module, {name, 3}) do
      quote do
        defoverridable [{unquote(name), 3}]

        @impl Phoenix.LiveComponent
        def unquote(name)(a, b, socket) do
          super(a, b, socket)
        catch
          kind, reason ->
            {:noreply, PhoenixDevToolbar.Panel.__break__(socket, kind, reason, __STACKTRACE__)}
        end
      end
    end
  end

  @doc false
  # render/1 only builds a %Rendered{}: its expressions run later, while
  # LiveView diffs it, outside any boundary. So the plugin's template is
  # evaluated once here (Phoenix.HTML.Safe, a public protocol) to catch an
  # error before LiveView sees it, at the cost of rendering it twice. A panel
  # that nests live components cannot be converted to HTML: it is not checked.
  # The plugin's render/1 is called here too, so code before its ~H is covered.
  @spec __checked__((-> Phoenix.LiveView.Rendered.t()), map()) :: Phoenix.LiveView.Rendered.t()
  def __checked__(render, assigns) do
    rendered = render.()
    check(rendered)
    rendered
  catch
    kind, reason -> render_failed(assigns, kind, reason, __STACKTRACE__)
  end

  defp check(rendered) do
    _ = Phoenix.HTML.Safe.to_iodata(rendered)
    :ok
  rescue
    exception in ArgumentError ->
      case LiveViewCompat.component_to_html_error?(exception) do
        true -> :ok
        false -> reraise exception, __STACKTRACE__
      end
  end

  # No socket in render: tell the toolbar (it shows the error), log once per
  # panel process, and render the broken placeholder.
  defp log_render_failure(nil = _first_time, id, kind, reason, stacktrace) do
    Logger.error(
      "[phoenix_dev_toolbar] panel #{inspect(id)} raised while rendering:\n" <>
        Exception.format(kind, reason, stacktrace)
    )
  end

  defp log_render_failure(_already_logged, _id, _kind, _reason, _stacktrace), do: :ok

  defp render_failed(assigns, kind, reason, stacktrace) do
    key = {Panel, :render_logged, assigns[:id]}

    log_render_failure(Process.put(key, true), assigns[:id], kind, reason, stacktrace)

    send(self(), {:pdt_panel_error, assigns[:id], Truncate.banner(kind, reason)})
    __broken__(assigns)
  end

  @doc false
  @spec __broken__(map()) :: Phoenix.LiveView.Rendered.t()
  def __broken__(assigns) do
    ~H"""
    <div id={@id} hidden></div>
    """
  end

  @doc false
  # Marks the tab broken and tells the toolbar (this component runs in the
  # panel LiveView's process), which shows the error and a Re-enable button.
  @spec __break__(Socket.t(), atom(), term(), Exception.stacktrace()) :: Socket.t()
  def __break__(socket, kind, reason, stacktrace) do
    Logger.error(
      "[phoenix_dev_toolbar] panel #{inspect(socket.assigns[:id])} raised:\n" <>
        Exception.format(kind, reason, stacktrace)
    )

    banner = Truncate.banner(kind, reason)
    socket = Phoenix.Component.assign(socket, pdt_error: banner, pdt_reported?: false)
    report(socket)
  end

  # The toolbar learns of the error by the component's id, which mount/1 does
  # not know yet: reported on the first update that has it.
  defp report(%Socket{assigns: %{pdt_error: banner, pdt_reported?: false, id: id}} = socket)
       when is_binary(banner) and is_binary(id) do
    send(self(), {:pdt_panel_error, id, banner})
    Phoenix.Component.assign(socket, :pdt_reported?, true)
  end

  defp report(socket), do: socket

  @doc false
  # The toolbar delivers events with send_update(module, id: id, pdt: {...});
  # everything else in `assigns` are the props rendered by the toolbar.
  @spec __update__(module(), map(), Socket.t()) :: {:ok, Socket.t()}
  def __update__(module, assigns, socket) do
    {delivery, props} = Map.pop(assigns, :pdt)
    socket = socket |> Phoenix.Component.assign(props) |> report()
    {:ok, deliver(module, delivery, socket)}
  end

  # Re-enable: forget the error, the reset that follows refills the tab.
  defp deliver(_module, :recover, socket) do
    Process.delete({Panel, :render_logged, socket.assigns[:id]})
    Phoenix.Component.assign(socket, pdt_error: nil, pdt_ready?: false)
  end

  defp deliver(_module, _delivery, %Socket{assigns: %{pdt_error: banner}} = socket)
       when is_binary(banner),
       do: socket

  defp deliver(module, delivery, socket) do
    socket = first_reset(socket, module)

    case delivery do
      {:reset, events} -> module.handle_reset(events, socket)
      {:events, events} -> module.handle_events(events, socket)
      {:info, message} -> module.handle_info(message, socket)
      nil -> maybe_handle_props(module, socket)
    end
  catch
    kind, reason -> __break__(socket, kind, reason, __STACKTRACE__)
  end

  # LiveView calls update/2 whenever the parent re-renders the component, even
  # with the same props: handle_props/1 only runs when one actually changed.
  defp maybe_handle_props(module, socket) do
    case Enum.any?([:page, :shown?, :visible?], &Phoenix.Component.changed?(socket, &1)) do
      true -> module.handle_props(socket)
      false -> socket
    end
  end

  # The first render comes before the toolbar delivers the page's events.
  defp first_reset(%Socket{assigns: %{pdt_ready?: true}} = socket, _module), do: socket

  defp first_reset(socket, module),
    do: [] |> module.handle_reset(socket) |> Phoenix.Component.assign(:pdt_ready?, true)
end
