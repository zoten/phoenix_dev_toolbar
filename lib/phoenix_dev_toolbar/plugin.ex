defmodule PhoenixDevToolbar.Plugin do
  @moduledoc """
  The behaviour every toolbar panel implements, the built-ins included (ADR 05).

  A plugin collects events from `:telemetry` inside the host's processes and,
  in the panel, folds them into summary badges (`c:summary_init/1`,
  `c:summary_add/2`, `c:badges/1`) and shows them in its own tab
  (`c:panel/0`, see `PhoenixDevToolbar.Panel`). Register plugins in `config/dev.exs`:

      config :phoenix_dev_toolbar,
        plugins: [:defaults, {MyApp.Toolbar.Jobs, queues: [:default]}]

  `:defaults` expands to the built-ins (Ecto, Request, LiveView). Listing a
  built-in with options overrides it; `{:exclude, Module}` removes one. An
  invalid entry is logged and skipped: the host application always boots.

  ## Example

      defmodule MyApp.Toolbar.Jobs do
        use PhoenixDevToolbar.Plugin, id: :jobs, name: "Jobs"

        alias PhoenixDevToolbar.{Context, Event}

        @impl PhoenixDevToolbar.Plugin
        def init(opts), do: {:ok, %{queues: Keyword.get(opts, :queues, :all)}}

        @impl PhoenixDevToolbar.Plugin
        def telemetry_events(_config), do: [[:oban, :engine, :insert_job, :stop]]

        @impl PhoenixDevToolbar.Plugin
        def collect(_event, {measurements, metadata}, %Context{}) do
          data = %{worker: metadata.job.worker}
          {:record, Event.new(:jobs, :inserted, data, duration: measurements.duration)}
        end
      end

  ## Where the code runs

  `init/1` runs once, when the toolbar attaches its handlers. `collect/3` runs
  **inside the host process** that emitted the event (a request, a LiveView,
  a Repo caller), and only for processes the toolbar tracks. So it must be
  cheap and pure:

    * never call another process synchronously, never do I/O
    * bound everything it keeps: `inspect/2` limits, never whole structs
    * never create atoms from runtime data

  A `collect/3` that raises, throws or exits is disabled (quarantined) and the
  error is logged once; the other plugins keep working.

  This behaviour is unstable before 1.0: changes are listed in the CHANGELOG.
  """

  alias PhoenixDevToolbar.Context
  alias PhoenixDevToolbar.Event

  @typedoc "What `init/1` returns: handed to every other callback."
  @type config :: term()

  @doc "A unique id, stored in every event the plugin records (`Event.plugin`)."
  @callback id() :: atom()

  @doc "The tab label in the panel."
  @callback name() :: String.t()

  @doc """
  Validates the options given in the config and returns the plugin's config.
  Runs once, in the toolbar's own process. Defaults to `{:ok, opts}`.
  """
  @callback init(opts :: keyword()) :: {:ok, config()} | {:error, String.t()}

  @doc "The `:telemetry` events to attach to."
  @callback telemetry_events(config()) :: [:telemetry.event_name()]

  @doc """
  Turns one telemetry event into a recorded event, or skips it. Runs inside the
  emitting host process: cheap, pure, never raises. `context.config` is the
  plugin's config.
  """
  @callback collect(
              :telemetry.event_name(),
              {measurements :: map(), metadata :: map()},
              Context.t()
            ) ::
              {:record, Event.t()} | :skip

  @typedoc """
  A badge of the summary bar, shown even when the panel is collapsed. `id`
  becomes the DOM id `pdt-badge-<id>`, unique in the whole panel: start it
  with your plugin's id. `title` is the tooltip.
  """
  @type badge :: %{
          required(:id) => String.t(),
          required(:text) => String.t(),
          required(:level) => :ok | :info | :warn | :error,
          optional(:title) => String.t()
        }

  @doc """
  The plugin's tab: a module that does `use PhoenixDevToolbar.Panel`. A plugin
  without it collects events and shows badges only.
  """
  @callback panel() :: module()

  @doc """
  The initial state of the plugin's summary for a page, folded by
  `c:summary_add/2` in the panel process, event by event: it survives the
  oldest events being trimmed from the buffer.
  """
  @callback summary_init(config()) :: term()

  @doc "Folds one of the plugin's events into its summary. Pure and cheap."
  @callback summary_add(summary :: term(), Event.t()) :: term()

  @doc "The summary bar badges for the summary, in display order."
  @callback badges(summary :: term()) :: [badge()]

  @optional_callbacks init: 1, panel: 0, summary_init: 1, summary_add: 2, badges: 1

  @doc """
  Sets the behaviour and defines `id/0`, `name/0` and a default `init/1`.

  Options: `:id` (required, an atom) and `:name` (the tab label, defaults to
  the id).
  """
  defmacro __using__(opts) do
    id = opts |> Keyword.get(:id) |> id!()
    name = opts |> Keyword.get(:name, Atom.to_string(id)) |> name!()

    quote do
      @behaviour PhoenixDevToolbar.Plugin

      @impl PhoenixDevToolbar.Plugin
      def id, do: unquote(id)

      @impl PhoenixDevToolbar.Plugin
      def name, do: unquote(name)

      @impl PhoenixDevToolbar.Plugin
      def init(opts), do: {:ok, opts}

      defoverridable init: 1
    end
  end

  # `:client` tags the LiveView tab's own client events.
  @reserved_ids [:client]

  @doc false
  @spec id!(term()) :: atom()
  def id!(id) when id in @reserved_ids,
    do: raise(ArgumentError, "use PhoenixDevToolbar.Plugin: id #{inspect(id)} is reserved")

  def id!(id) when is_atom(id) and not is_nil(id) and not is_boolean(id), do: id

  def id!(id),
    do:
      raise(
        ArgumentError,
        "use PhoenixDevToolbar.Plugin expects id: an atom, got: #{Macro.to_string(id)}"
      )

  @doc false
  @spec name!(term()) :: String.t()
  def name!(name) when is_binary(name), do: name

  def name!(name),
    do:
      raise(
        ArgumentError,
        "use PhoenixDevToolbar.Plugin expects name: a string, got: #{Macro.to_string(name)}"
      )

  @doc false
  @spec reserved_ids() :: [atom()]
  def reserved_ids, do: @reserved_ids
end
