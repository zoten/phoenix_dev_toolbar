defmodule PhoenixDevToolbar.Session do
  @moduledoc false
  # One page view: a dead render request or a LiveView process (ADR 02).
  # `count`, `dropped` and `trimmed` are filled from the Store counters when read.

  alias PhoenixDevToolbar.Session

  @enforce_keys [:sid, :kind, :started_at]
  defstruct sid: nil,
            parent: nil,
            kind: nil,
            owner: nil,
            transport: nil,
            view: nil,
            path: nil,
            label: nil,
            started_at: nil,
            count: 0,
            dropped: 0,
            trimmed: 0

  @type sid :: String.t()
  @type kind :: :request | :live_view

  @type t :: %Session{
          sid: sid(),
          parent: sid() | nil,
          kind: kind(),
          owner: pid() | nil,
          transport: pid() | nil,
          view: module() | nil,
          path: String.t() | nil,
          label: String.t() | nil,
          started_at: integer(),
          count: non_neg_integer(),
          dropped: non_neg_integer(),
          trimmed: non_neg_integer()
        }

  @fields [:parent, :owner, :transport, :view, :path, :label]

  @doc """
  Builds a session with a fresh sid, stamped with the current system time in
  microseconds. Accepts `:parent`, `:owner`, `:transport`, `:view`, `:path` and `:label`.
  """
  @spec new(kind(), keyword()) :: t()
  def new(kind, attrs \\ []) when kind in [:request, :live_view] do
    struct!(
      %Session{sid: new_sid(), kind: kind, started_at: System.system_time(:microsecond)},
      Keyword.take(attrs, @fields)
    )
  end

  @doc """
  Returns a random, URL safe session id.

      iex> PhoenixDevToolbar.Session.new_sid() =~ ~r/^[A-Za-z0-9_-]{16}$/
      true

  """
  @spec new_sid() :: sid()
  def new_sid, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
