defmodule PhoenixDevToolbar.Label do
  @moduledoc false
  # The actor label of a page request (ADR 13, 15): who a page belongs to when
  # several people or personas use one dev server. Resolved in the plug's
  # `before_send`, inside the host's request process, once per tracked page:
  # it never raises and reads no request state it does not need (no
  # `fetch_query_params`, no `fetch_cookies`: they would mutate the host conn).

  require Logger

  alias PhoenixDevToolbar.Config
  alias PhoenixDevToolbar.Session
  alias PhoenixDevToolbar.Store
  alias PhoenixDevToolbar.Truncate
  alias Plug.Conn
  alias Plug.Conn.Cookies

  @cookie "_pdt_label"
  @param "pdt_label"
  @max_bytes 64
  @max_hops 10
  @flag {__MODULE__, :function_failed}

  @doc """
  Resolves the label of `conn` and applies the `?pdt_label=` cookie change.
  Precedence: the param, the `_pdt_label` cookie, the `label:` function.
  Returns the conn (cookie set or cleared) and the label, or nil. Never raises.
  """
  @spec resolve(Conn.t()) :: {Conn.t(), String.t() | nil}
  def resolve(%Conn{} = conn) do
    {conn, tagged} = tag_param(conn)

    label =
      case tagged do
        nil -> cookie_label(conn) || function_label(conn)
        :cleared -> function_label(conn)
        label -> label
      end

    {conn, label}
  rescue
    _error -> {conn, nil}
  catch
    _kind, _reason -> {conn, nil}
  end

  @doc "Writes `label` on the request session: one ETS update, nothing when nil."
  @spec store(Session.sid(), String.t() | nil) :: :ok | :error
  def store(_sid, nil), do: :ok
  def store(sid, label), do: Store.put_label(sid, label)

  @doc "Cleans a label: printable, trimmed, at most 64 bytes on a UTF-8 boundary; nil when empty or not text."
  @spec sanitize(term()) :: String.t() | nil
  def sanitize(label) when is_binary(label) do
    label
    |> String.replace_invalid("")
    |> String.replace(~r/[\p{Cc}\p{Zl}\p{Zp}]/u, "")
    |> String.trim()
    |> Truncate.prefix(@max_bytes)
    |> String.trim()
    |> blank_to_nil()
  end

  def sanitize(_other), do: nil

  @doc """
  Gives every session without a label its request ancestor's, walking `parent`
  at most #{@max_hops} hops (so a cycle ends). A read time rule: the hot path
  writes the label on the request only.
  """
  @spec inherit([Session.t()]) :: [Session.t()]
  def inherit(sessions) do
    by_sid = Map.new(sessions, &{&1.sid, &1})
    Enum.map(sessions, &inherited(&1, by_sid))
  end

  defp inherited(%Session{label: nil, parent: parent} = session, by_sid) when is_binary(parent),
    do: %{session | label: ancestor_label(parent, by_sid, @max_hops)}

  defp inherited(session, _by_sid), do: session

  defp ancestor_label(_sid, _by_sid, 0), do: nil

  defp ancestor_label(sid, by_sid, hops) do
    case by_sid do
      %{^sid => %Session{label: nil, parent: parent}} when is_binary(parent) ->
        ancestor_label(parent, by_sid, hops - 1)

      %{^sid => %Session{label: label}} ->
        label

      _unknown ->
        nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  ## `?pdt_label=`

  defp tag_param(%Conn{query_string: query} = conn) do
    case String.contains?(query, @param <> "=") do
      true -> conn |> apply_param(URI.decode_query(query))
      false -> {conn, nil}
    end
  end

  defp apply_param(conn, %{@param => value}) when is_binary(value) do
    case sanitize(value) do
      nil ->
        {Conn.delete_resp_cookie(conn, @cookie, cookie_opts()), :cleared}

      label ->
        {Conn.put_resp_cookie(
           conn,
           @cookie,
           Base.url_encode64(label, padding: false),
           cookie_opts()
         ), label}
    end
  end

  defp apply_param(conn, _params), do: {conn, nil}

  # Session lifetime (no max_age), dev only: the plug is a no-op in prod.
  defp cookie_opts, do: [http_only: true, same_site: "Lax", path: "/"]

  defp cookie_label(%Conn{} = conn) do
    header = conn |> Conn.get_req_header("cookie") |> Enum.join("; ")

    with true <- String.contains?(header, @cookie <> "="),
         %{@cookie => encoded} <- Cookies.decode(header),
         {:ok, text} <- Base.url_decode64(encoded, padding: false) do
      sanitize(text)
    else
      _none -> nil
    end
  end

  ## `label:` function

  defp function_label(conn) do
    case Config.label() do
      nil -> nil
      fun -> conn |> call(fun) |> sanitize()
    end
  end

  defp call(conn, {module, function}) do
    apply(module, function, [conn])
  catch
    kind, reason -> failed(kind, reason)
  end

  defp call(conn, fun) when is_function(fun, 1) do
    fun.(conn)
  catch
    kind, reason -> failed(kind, reason)
  end

  # `catch kind, reason` covers raise, throw and exit.
  defp failed(kind, reason) do
    case :persistent_term.get(@flag, false) do
      true ->
        nil

      false ->
        :persistent_term.put(@flag, true)

        Logger.warning(
          "[phoenix_dev_toolbar] label: function failed, pages get no label from it " <>
            "(logged once): " <> Truncate.banner(kind, reason)
        )

        nil
    end
  end
end
