defmodule PhoenixDevToolbar.ProcessActions do
  @moduledoc false
  # What the panel does to host processes (ADR 10): kill, suspend, peek at
  # messages. Each one asks ClientPolicy (`actions:`, loopback by default) about
  # the panel's client; kill and suspend also ask Protected about the target.
  # Kills and suspensions are logged. Reasons come from the client as strings
  # and are matched, never turned into atoms.

  require Logger

  alias PhoenixDevToolbar.ClientPolicy
  alias PhoenixDevToolbar.ProcessInfo
  alias PhoenixDevToolbar.Protected
  alias PhoenixDevToolbar.Suspender
  alias PhoenixDevToolbar.Truncate

  @suspend_ms 10_000
  # Message peek: only below this queue length, at most this many messages shown.
  @peek_below 100
  @peek_count 10

  @type context :: %{
          required(:panel) => pid(),
          optional(:client) => :inet.ip_address() | nil,
          optional(:transport) => pid() | nil,
          optional(:endpoint) => module() | nil
        }

  @doc "How long a suspension lasts, in ms."
  @spec suspend_ms() :: pos_integer()
  def suspend_ms, do: @suspend_ms

  @doc "Whether this panel's client may act at all: why not, as text, when it may not."
  @spec client(context()) :: :ok | {:error, String.t()}
  def client(context) do
    case ClientPolicy.check_actions(context[:client]) do
      :ok ->
        :ok

      {:error, :disabled} ->
        {:error, "Actions are off: `actions: false` in the toolbar config."}

      {:error, :not_loopback} ->
        {:error,
         "Actions only run for a browser on this machine. From Docker or the LAN, set " <>
           "`actions: :any` in config/dev.exs (anyone who reaches the dev server can then use them)."}
    end
  end

  @doc "Whether this panel may kill or suspend `pid`: why not, as text, when it may not."
  @spec allowed(pid(), context()) :: :ok | {:error, String.t()}
  def allowed(pid, context) do
    with :ok <- client(context) do
      case Protected.check(pid, context) do
        :ok -> :ok
        {:error, why} -> {:error, "Protected: #{why}."}
      end
    end
  end

  @doc """
  Kills `pid`: `"kill"` (untrappable), `"shutdown"`, or `"crash"` (an exit with a
  RuntimeError, as a crash shows in logs and to supervisors).
  """
  @spec kill(pid(), String.t(), context()) :: :ok | {:error, String.t()}
  def kill(pid, reason, context) do
    with {:ok, exit_reason} <- exit_reason(reason),
         :ok <- allowed(pid, context) do
      label = label(pid)
      true = Process.exit(pid, exit_reason)

      Logger.warning(
        "[phoenix_dev_toolbar] killed #{inspect(pid)} (#{label}) with #{reason} from the panel"
      )
    end
  end

  defp exit_reason("kill"), do: {:ok, :kill}
  defp exit_reason("shutdown"), do: {:ok, :shutdown}

  defp exit_reason("crash"),
    do: {:ok, {%RuntimeError{message: "killed from the dev toolbar"}, []}}

  defp exit_reason(_other), do: {:error, "Unknown kill reason."}

  @doc "Suspends `pid` for #{@suspend_ms} ms; the Suspender resumes it."
  @spec suspend(pid(), context()) :: :ok | {:error, String.t()}
  def suspend(pid, context) do
    with :ok <- allowed(pid, context) do
      case Suspender.suspend(pid, @suspend_ms, context.panel) do
        :ok ->
          Logger.warning(
            "[phoenix_dev_toolbar] suspended #{inspect(pid)} (#{label(pid)}) " <>
              "for #{div(@suspend_ms, 1000)}s from the panel"
          )

        {:error, reason} ->
          {:error, suspend_error(reason)}
      end
    end
  end

  defp suspend_error(:too_many), do: "Ten processes are suspended already: resume one first."
  defp suspend_error(:already), do: "It is suspended already."
  defp suspend_error(:dead), do: "It has exited."
  defp suspend_error(:ttl), do: "Invalid duration."
  defp suspend_error(:unavailable), do: "The toolbar's suspender is restarting: try again."

  @doc "Resumes `pid` if the toolbar suspended it. Always allowed: it only undoes."
  @spec resume(pid()) :: :ok | {:error, String.t()}
  def resume(pid) do
    case Suspender.resume(pid) do
      :ok -> :ok
      {:error, :not_suspended} -> {:error, "It was not suspended by the toolbar."}
      {:error, :unavailable} -> {:error, "The toolbar's suspender is restarting: try again."}
    end
  end

  @doc """
  The first #{@peek_count} messages in `pid`'s queue, redacted and truncated, and
  the queue's length. Only while it holds fewer than #{@peek_below}: reading the
  queue copies all of it.
  """
  @spec peek(pid(), context()) :: {:ok, [String.t()], non_neg_integer()} | {:error, String.t()}
  def peek(pid, context) do
    with :ok <- client(context) do
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, length} when length < @peek_below ->
          read_messages(pid)

        {:message_queue_len, length} ->
          {:error, "#{length} messages queued: peek reads fewer than #{@peek_below}."}

        nil ->
          {:error, "It has exited."}
      end
    end
  end

  # The queue may have grown since its length was read: still at most what came in.
  defp read_messages(pid) do
    case Process.info(pid, :messages) do
      {:messages, messages} ->
        shown =
          messages
          |> Enum.take(@peek_count)
          |> Enum.map(&(&1 |> Truncate.redact() |> Truncate.inspect_value()))

        {:ok, shown, length(messages)}

      nil ->
        {:error, "It has exited."}
    end
  end

  defp label(pid) do
    case ProcessInfo.about(pid) do
      %{name: name} when is_binary(name) -> name
      %{initial_call: call} -> call
      nil -> "exited"
    end
  end
end
