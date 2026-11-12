defmodule PhoenixDevToolbar.ComponentTree do
  @moduledoc false
  # Component tree of the page for the LiveView tab (ADR 07). Runs in the
  # panel's start_async task, never in a host process: it calls the page's
  # LiveViews through Phoenix.LiveView.Debug (GenServer.call) and keeps only
  # module, id and cid of each component (assigns are dropped at once), at most
  # @max_nodes nodes for the whole page.

  alias Phoenix.LiveView.Debug
  alias PhoenixDevToolbar.LiveViewCompat
  alias PhoenixDevToolbar.Truncate

  @max_nodes 500
  @id_inspect [limit: 5, printable_limit: 128]

  @type component :: %{
          module: module(),
          id: String.t(),
          cid: non_neg_integer(),
          children: [component()]
        }
  @type view :: %{
          view: module(),
          root: String.t() | nil,
          nested?: boolean(),
          components: [component()]
        }
  @type t :: %{views: [view()], truncated?: boolean()}

  @doc """
  Reads the tree of the page whose LiveView is `root`; `pids` are every process
  tracked as the page (nested LiveViews, shown under the root).
  """
  @spec read(pid(), [pid()]) :: t()
  def read(root, pids) do
    {views, left} =
      [root | List.delete(pids, root)]
      |> Enum.flat_map(&labelled/1)
      |> Enum.map_reduce(@max_nodes, fn {pid, view, dom_id}, left ->
        {components, used} = build(live_components(pid), left)

        {%{view: view, root: dom_id, nested?: pid != root, components: components}, left - used}
      end)

    %{views: views, truncated?: left <= 0}
  end

  defp labelled(pid) do
    case LiveViewCompat.live_view_root(pid) do
      {:ok, view, dom_id} -> [{pid, view, dom_id}]
      :error -> []
    end
  end

  defp live_components(pid) do
    case Debug.live_components(pid) do
      {:ok, components} -> components
      {:error, _reason} -> []
    end
  end

  @doc """
  Nests `Debug.live_components/1` entries by `children_cids`, at most `budget`
  nodes. Returns the roots and the number of nodes used. Unknown cids and
  cycles are skipped.
  """
  @spec build([map()], non_neg_integer()) :: {[component()], non_neg_integer()}
  def build(components, budget \\ @max_nodes) do
    by_cid =
      Map.new(components, fn %{cid: cid} = component ->
        {cid, {component.module, component.id, component[:children_cids] || []}}
      end)

    children =
      for {_cid, {_module, _id, cids}} <- by_cid, cid <- cids, into: MapSet.new(), do: cid

    roots = by_cid |> Map.keys() |> Enum.reject(&MapSet.member?(children, &1)) |> Enum.sort()

    {nodes, left} = expand(roots, by_cid, %{}, budget)
    {nodes, budget - left}
  end

  defp expand([], _by_cid, _seen, left), do: {[], left}
  defp expand(_cids, _by_cid, _seen, left) when left <= 0, do: {[], left}

  defp expand([cid | rest], by_cid, seen, left) do
    case {Map.fetch(by_cid, cid), is_map_key(seen, cid)} do
      {{:ok, {module, id, child_cids}}, false} ->
        seen = Map.put(seen, cid, true)
        {children, left} = expand(child_cids, by_cid, seen, left - 1)
        {siblings, left} = expand(rest, by_cid, seen, left)

        node = %{
          module: module,
          id: Truncate.inspect_value(id, @id_inspect),
          cid: cid,
          children: children
        }

        {[node | siblings], left}

      _unknown_or_seen ->
        expand(rest, by_cid, seen, left)
    end
  end
end
