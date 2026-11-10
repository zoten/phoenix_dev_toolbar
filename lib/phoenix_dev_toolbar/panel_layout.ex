defmodule PhoenixDevToolbar.PanelLayout do
  @moduledoc false
  # The panel's markup (ADR 04, ADR 05): header with the summary bar and the
  # plugins' tabs, one section per tab with its component, and the disabled
  # state of a plugin after an error. State lives in PhoenixDevToolbar.PanelLive.

  use Phoenix.Component

  import PhoenixDevToolbar.Components

  alias PhoenixDevToolbar.Page
  alias PhoenixDevToolbar.Shell

  @doc "The DOM id of a tab's component."
  @spec panel_id(String.t()) :: String.t()
  def panel_id(tab_id), do: "pdt-panel-" <> tab_id

  attr :shell, Shell, required: true
  attr :tabs, :list, required: true, doc: "Shell.tabs/1"
  attr :tab, :string, default: nil, doc: "the selected tab id"
  attr :page, Page, required: true
  attr :gaps, :map, required: true, doc: "PageData.gaps/1"
  attr :quarantined, :map, required: true, doc: "tab id => banner, from the collector"
  attr :panel_errors, :map, required: true, doc: "tab id => banner, from the tab's component"
  attr :missing?, :boolean, required: true
  attr :visible?, :boolean, required: true
  attr :pdt_actions, :map, default: %{}, doc: "internal: ProcessActions context"

  def panel(assigns) do
    ~H"""
    <%!-- data-pdt-* attributes are a contract for agents (ADR 14). --%>
    <div
      id="pdt-panel"
      class="pdt-panel"
      data-pdt-root={@page.root}
      data-pdt-sids={Enum.join(@page.sids, ",")}
    >
      <%!-- The hook lives on its own empty element: LiveView locks a hook's
           element while its pushEvent is in flight, and a diff landing in a
           locked tree loses its stream resets (seen on live navigation). --%>
      <div id="pdt-bridge" phx-hook="PdtPanel" hidden></div>
      <header class="pdt-header">
        <span class="pdt-logo">dev toolbar</span>
        <%!-- Shown by CSS while a joined panel has lost its connection
             (LiveView's phx-client-error / phx-server-error, assets/css/panel.css). --%>
        <span
          id="pdt-offline"
          class="pdt-offline"
          role="status"
          title="The connection to the server is lost: what the toolbar shows is frozen until it reconnects"
        >
          Disconnected · reconnecting<span class="pdt-sr-only">: what the toolbar shows is frozen until it reconnects</span>
        </span>
        <.summary_bar badges={Shell.badges(@shell)} dropped={@gaps.dropped} trimmed={@gaps.trimmed} />
        <%!-- Counts the badges the collapsed bar has no room for (assets/js/panel.js). --%>
        <button
          id="pdt-summary-more"
          type="button"
          class="pdt-badge pdt-badge--button pdt-summary-more"
          phx-hook="PdtSummaryMore"
          phx-update="ignore"
          data-pdt-open
          title="More badges: open the toolbar to see them all"
          hidden
        ></button>
        <button
          :for={{id, name, banner} <- disabled_without_tab(@shell, @tabs, @quarantined)}
          id={"pdt-badge-disabled-" <> id}
          type="button"
          class="pdt-badge pdt-badge--error pdt-badge--button"
          title={banner}
          phx-click="pdt_reenable"
          phx-value-tab={id}
        >
          {name} disabled · re-enable
        </button>
        <nav class="pdt-tabs" role="tablist">
          <button
            :for={tab <- @tabs}
            id={"pdt-tab-" <> tab.id}
            type="button"
            role="tab"
            aria-selected={to_string(@tab == tab.id)}
            aria-controls={"pdt-section-" <> tab.id}
            tabindex={if(@tab == tab.id, do: "0", else: "-1")}
            class={[
              "pdt-tab",
              @tab == tab.id && "pdt-tab--active",
              tab_error(@quarantined, @shell, @panel_errors, tab.id) && "pdt-tab--error"
            ]}
            phx-click="tab"
            phx-value-tab={tab.id}
          >
            {tab.name}
          </button>
        </nav>
        <%!-- Where the toolbar docks: client side only, the loader moves it
             (assets/js/panel.js, ADR 04). Ignored by patches: panel.js owns
             the menu's hidden and pressed state. --%>
        <div id="pdt-dock-picker" class="pdt-dock-picker" phx-update="ignore">
          <button
            id="pdt-dock"
            type="button"
            class="pdt-dock"
            data-pdt-dock-menu
            aria-haspopup="true"
            aria-expanded="false"
            aria-controls="pdt-dock-menu"
            aria-label="Move the toolbar"
            title="Dock position"
          >
            <span class="pdt-dock__icon" aria-hidden="true"></span>
          </button>
          <div
            id="pdt-dock-menu"
            class="pdt-dock-menu"
            role="group"
            aria-label="Dock the toolbar"
            hidden
          >
            <button
              :for={dock <- ~w(bottom top left right)}
              id={"pdt-dock-" <> dock}
              type="button"
              class="pdt-dock-option"
              data-pdt-dock={dock}
              aria-pressed="false"
            >
              <span class={["pdt-dock__icon", "pdt-dock__icon--" <> dock]} aria-hidden="true"></span>
              {String.capitalize(dock)}
            </button>
            <%!-- Pressed state from the loader (pdt:state); the choice is stored
                 per browser and overrides the reserve_space config. --%>
            <button
              id="pdt-reserve"
              type="button"
              class="pdt-dock-option pdt-dock-reserve"
              data-pdt-reserve
              aria-pressed="true"
              title="Make room so the page scrolls clear of the toolbar"
            >
              <span class="pdt-reserve__check" aria-hidden="true"></span> Reserve page space
            </button>
          </div>
        </div>
        <button
          id="pdt-hide"
          type="button"
          class="pdt-hide"
          data-pdt-hide
          aria-label="Hide the toolbar to a corner badge"
          title="Hide"
        >
          <span aria-hidden="true">&times;</span>
        </button>
        <button
          id="pdt-toggle"
          type="button"
          class="pdt-toggle"
          data-pdt-toggle
          aria-label="Expand or collapse the toolbar"
        >
          <span class="pdt-toggle__icon" aria-hidden="true"></span>
        </button>
      </header>

      <p :if={@missing?} id="pdt-empty" class="pdt-empty">
        No data for this page: it expired or the toolbar restarted. Reload the page.
      </p>

      <section
        :for={tab <- @tabs}
        id={"pdt-section-" <> tab.id}
        class="pdt-section"
        data-pdt-tab={tab.id}
        role="tabpanel"
        aria-labelledby={"pdt-tab-" <> tab.id}
        hidden={@tab != tab.id}
      >
        <p
          :if={Map.get(@gaps.by_plugin, tab.id, 0) > 0}
          id={"pdt-trimmed-" <> tab.id}
          class="pdt-hint"
        >
          {Map.get(@gaps.by_plugin, tab.id)} older events trimmed: the list starts later than the page.
        </p>
        <div
          :if={tab_error(@quarantined, @shell, @panel_errors, tab.id)}
          id={"pdt-disabled-" <> tab.id}
          class="pdt-disabled"
          role="alert"
        >
          <p>{tab.name} is disabled after an error. The rest of the toolbar keeps working.</p>
          <pre class="pdt-error">{tab_error(@quarantined, @shell, @panel_errors, tab.id)}</pre>
          <button
            id={"pdt-reenable-" <> tab.id}
            type="button"
            class="pdt-button"
            phx-click="pdt_reenable"
            phx-value-tab={tab.id}
          >
            Re-enable
          </button>
        </div>
        <.live_component
          module={tab.panel}
          id={panel_id(tab.id)}
          config={tab.config}
          page={@page}
          shown?={@tab == tab.id}
          visible?={@visible?}
          {internal_assigns(tab, @pdt_actions)}
        />
      </section>
    </div>
    """
  end

  # A disabled plugin without a tab would vanish silently: say so in the bar.
  defp disabled_without_tab(shell, tabs, quarantined) do
    tab_ids = MapSet.new(tabs, & &1.id)

    for {plugin, _config} <- shell.plugins,
        id = Atom.to_string(plugin.id()),
        not MapSet.member?(tab_ids, id),
        banner = quarantined[id] || Shell.broken(shell)[id],
        do: {id, plugin.name(), banner}
  end

  # Why a tab is disabled: its collector, its summary or its component raised.
  defp tab_error(quarantined, shell, panel_errors, tab_id),
    do: quarantined[tab_id] || Shell.broken(shell)[tab_id] || panel_errors[tab_id]

  # What only the built-in tabs get (ADR 10): the actions' context holds the
  # client's address and the panel's own processes, nothing a plugin needs.
  # An explicit list: a plugin naming its panel under PhoenixDevToolbar. gets nothing.
  @internal_panels [
    PhoenixDevToolbar.Panels.Process,
    PhoenixDevToolbar.Panels.System,
    PhoenixDevToolbar.Panels.Eval
  ]

  defp internal_assigns(%{panel: panel}, pdt_actions) when panel in @internal_panels,
    do: [pdt_actions: pdt_actions]

  defp internal_assigns(_tab, _pdt_actions), do: []
end
