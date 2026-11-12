defmodule PhoenixDevToolbar.Inspected do
  @moduledoc false
  # The element the user picked on the host page (ADR 16). The payload comes
  # from the loader, which read the host DOM: untrusted input. `parse/1` is the
  # only way in: strings are bounded, integers ranged, lists capped, invalid
  # fields dropped, no atoms created, never a raise. Editor links are built only
  # from validated relative paths and Phoenix's PLUG_EDITOR template.

  alias PhoenixDevToolbar.Inspected

  @max_string 512
  @max_frames 20
  @max_integer 10_000_000
  @bindings ~w(phx-click phx-submit phx-change)

  defstruct root: nil, cid: nil, tag: nil, tag_line: nil, binding: nil, frames: [], caller: nil

  @type frame :: %{name: String.t(), file: String.t() | nil, line: non_neg_integer() | nil}
  @type t :: %Inspected{
          root: String.t() | nil,
          cid: non_neg_integer() | nil,
          tag: String.t() | nil,
          tag_line: non_neg_integer() | nil,
          binding: %{event: String.t(), name: String.t(), target: String.t() | nil} | nil,
          frames: [frame()],
          caller: %{file: String.t() | nil, line: non_neg_integer() | nil} | nil
        }

  @doc "Validates the loader's payload; `:error` when it is not a map."
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(%{} = payload) do
    {:ok,
     %Inspected{
       root: string(payload["root"]),
       cid: integer(payload["cid"]),
       tag: string(payload["tag"]),
       tag_line: integer(payload["tag_line"]),
       binding: parse_binding(payload["binding"]),
       frames: frames(payload["frames"]),
       caller: caller(payload["caller"])
     }}
  end

  def parse(_other), do: :error

  defp string(value) when is_binary(value) do
    value |> binary_part(0, min(byte_size(value), @max_string)) |> valid_prefix()
  end

  defp string(_value), do: nil

  # The longest valid UTF-8 prefix: a cut inside a character drops its bytes.
  defp valid_prefix(""), do: nil

  defp valid_prefix(binary) do
    case String.valid?(binary) do
      true -> binary
      false -> binary |> binary_part(0, byte_size(binary) - 1) |> valid_prefix()
    end
  end

  defp integer(value) when is_integer(value) and value in 0..@max_integer, do: value
  defp integer(_value), do: nil

  defp parse_binding(%{"event" => event, "name" => name} = map) when event in @bindings do
    case string(name) do
      nil -> nil
      name -> %{event: event, name: name, target: string(map["target"])}
    end
  end

  defp parse_binding(_value), do: nil

  defp frames(list) when is_list(list) do
    list |> Enum.take(@max_frames) |> Enum.flat_map(&frame/1)
  end

  defp frames(_value), do: []

  defp frame(%{"name" => name} = map) when is_binary(name) do
    case string(name) do
      nil -> []
      name -> [%{name: name, file: string(map["file"]), line: integer(map["line"])}]
    end
  end

  defp frame(_value), do: []

  defp caller(%{"file" => file} = map) when is_binary(file),
    do: %{file: string(file), line: integer(map["line"])}

  defp caller(_value), do: nil

  @blocked_schemes ~w(javascript data vbscript file)

  @doc """
  The editor (`PLUG_EDITOR`, Phoenix's convention) read at use time: the
  template and the working directory, or nil without a template or a cwd.
  """
  @spec editor() :: {String.t(), String.t()} | nil
  def editor do
    with template when is_binary(template) <- System.get_env("PLUG_EDITOR"),
         {:ok, cwd} <- File.cwd() do
      {template, cwd}
    else
      _ -> nil
    end
  end

  @doc """
  The editor link for a frame (`%{file:, line:}`), or nil: the template must
  start with a URL scheme (letters, then `://`) that is not `javascript`,
  `data`, `vbscript` or `file`, the file must be relative without `..` segments
  or backslashes. `__FILE__` becomes the absolute path, `__LINE__` the line.
  """
  @spec editor_url(
          %{file: String.t() | nil, line: non_neg_integer() | nil},
          {String.t(), String.t()} | nil
        ) :: String.t() | nil
  def editor_url(%{file: file} = frame, {template, cwd})
      when is_binary(file) and is_binary(template) and is_binary(cwd) do
    with true <- safe_scheme?(template),
         true <- safe_file?(file) do
      template
      |> String.replace("__FILE__", URI.encode(Path.join(cwd, file)))
      |> String.replace("__LINE__", Integer.to_string(frame[:line] || 1))
    else
      _ -> nil
    end
  end

  def editor_url(_frame, _editor), do: nil

  defp safe_scheme?(template) do
    case Regex.run(~r/\A([a-zA-Z]+):\/\//, template) do
      [_, scheme] -> String.downcase(scheme) not in @blocked_schemes
      nil -> false
    end
  end

  defp safe_file?(file) do
    segments = Path.split(file)

    file != "" and Path.type(file) == :relative and ".." not in segments and
      not String.contains?(file, [<<0>>, "\\"])
  end
end
