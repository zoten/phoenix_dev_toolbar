defmodule PhoenixDevToolbar.Protected do
  @moduledoc false
  # The processes the toolbar never kills or suspends (ADR 10). Reads and GC are
  # allowed on them; only destructive actions ask here. Killing or freezing one
  # of these takes down the toolbar, the panel's own connection or the node.
  #
  # Cheap and call free: registered name and dictionary reads through
  # ProcessInfo, and :application.get_application/1, which is a group leader
  # read plus an ETS match on application_controller's table (no call into it).

  alias PhoenixDevToolbar.ProcessInfo

  @type context :: %{
          required(:panel) => pid(),
          optional(:transport) => pid() | nil,
          optional(:endpoint) => module() | nil
        }

  @core_names [
    :init,
    :erl_prim_loader,
    :code_server,
    :application_controller,
    :kernel_sup,
    :kernel_safe_sup,
    :logger,
    :logger_sup,
    :user,
    :standard_error,
    :file_server_2,
    :global_name_server,
    :inet_db,
    :rex,
    :erts_code_purger,
    :elixir_config,
    :elixir_code_server,
    :erl_signal_server,
    :socket_registry,
    :erts_literal_area_collector,
    :erts_dirty_process_signal_handler,
    :global_group,
    :kernel_refc
  ]

  @core_apps [:kernel, :stdlib, :elixir, :logger, :compiler]

  @doc "`:ok` when `pid` may be killed or suspended, or why not."
  @spec check(pid(), context()) :: :ok | {:error, String.t()}
  def check(pid, _context) when is_pid(pid) and node(pid) != node(),
    do: {:error, "it runs on another node"}

  def check(pid, context) when is_pid(pid) do
    cond do
      pid == context.panel -> {:error, "it is this panel"}
      pid == context[:transport] -> {:error, "it carries this panel's connection"}
      endpoint?(pid, context[:endpoint]) -> {:error, "it is the host endpoint"}
      ProcessInfo.toolbar?(pid) -> {:error, "it is part of the dev toolbar"}
      true -> core(pid)
    end
  end

  defp endpoint?(pid, endpoint) when is_atom(endpoint) and not is_nil(endpoint),
    do: Process.whereis(endpoint) == pid

  defp endpoint?(_pid, _endpoint), do: false

  defp core(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when name in @core_names -> {:error, "it is a core OTP process"}
      _other -> master(pid)
    end
  end

  # An application master is its application's group leader: killing the master
  # of a permanent application stops the node. Its `$initial_call` names it (its
  # `initial_call` is proc_lib's).
  defp master(pid) do
    case ProcessInfo.module(pid) do
      :application_master -> {:error, "it is an application master"}
      _other -> application(pid)
    end
  end

  defp application(pid) do
    case :application.get_application(pid) do
      {:ok, app} when app in @core_apps -> {:error, "it belongs to the #{app} application"}
      _other -> :ok
    end
  end
end
