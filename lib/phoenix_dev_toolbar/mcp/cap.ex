defmodule PhoenixDevToolbar.Mcp.Cap do
  @moduledoc false
  # The hard cap on a tool result's size (ADR 15, `max_result_bytes:`). The
  # result is measured once, then row sizes are subtracted without encoding the
  # whole result again. Pure: it never reads the Store.

  alias PhoenixDevToolbar.Mcp.Json

  @row_tools ~w(list_pages page_queries page_callbacks page_errors recent_errors page_assigns_shape)
  @row_keys ~w(pages queries groups callbacks errors assigns)
  @footer_marker "\n---\nsid `"

  @type cap :: pos_integer() | :infinity

  @doc """
  Cuts `result` (already `Json.safe/1`d) to `cap` bytes of JSON text; the
  `page_report` Markdown is measured as its own text block. `offset` is the
  rows skipped by the call (row tools). A result under the cap is returned as is.
  """
  @spec apply(String.t(), Json.json(), cap(), non_neg_integer() | nil) :: Json.json()
  def apply(_name, result, :infinity, _offset), do: result

  def apply("page_report", %{"markdown" => markdown} = result, cap, _offset)
      when is_binary(markdown) do
    case byte_size(markdown) > cap do
      true -> cut_markdown(result, markdown, cap)
      false -> result
    end
  end

  def apply(name, result, cap, offset) when is_map(result) do
    size = byte_size(Json.encode!(result))

    case size > cap do
      false -> result
      true -> cut(name, result, size, cap, offset)
    end
  end

  def apply(_name, result, _cap, _offset), do: result

  # Row tools

  defp cut(name, result, size, cap, offset) when name in @row_tools do
    case Enum.find(@row_keys, &is_list(Map.get(result, &1))) do
      nil -> cut_nested(name, result, size, cap)
      key -> cut_rows(name, result, key, size, cap, offset || 0)
    end
  end

  defp cut(name, result, size, cap, _offset), do: cut_nested(name, result, size, cap)

  defp cut_rows(name, result, key, size, cap, offset) do
    rows = Map.fetch!(result, key)
    total = length(rows)
    sizes = Enum.map(rows, &(byte_size(Json.encode!(&1)) + 1))
    # What stays when every row goes (the envelope), plus the room the added keys need.
    envelope = size - Enum.sum(sizes) + 1
    base = envelope + reserve(rows_hint(:cut, name, total, total, cap, offset))
    keep = fitting(sizes, cap - base, 0)
    reason = zero_reason(keep, sizes, cap - base)

    result
    |> Map.put(key, Enum.take(rows, keep))
    |> maybe_put_returned(keep)
    |> Map.put("truncated", true)
    |> maybe_put_next(reason, keep, offset)
    |> Map.put("hint", rows_hint(reason, name, keep, total, cap, offset))
  end

  # Why nothing fits: the first row is bigger than the room left after the fixed
  # fields and the hint, or those alone are over the cap.
  defp zero_reason(0, [first | _], room) when room > 0 and first > room, do: :big_row
  defp zero_reason(0, _sizes, _room), do: :small_cap
  defp zero_reason(_keep, _sizes, _room), do: :cut

  defp fitting([size | rest], room, kept) when size <= room,
    do: fitting(rest, room - size, kept + 1)

  defp fitting(_sizes, _room, kept), do: kept

  defp maybe_put_returned(result, keep) do
    case is_map_key(result, "returned") do
      true -> Map.put(result, "returned", keep)
      false -> result
    end
  end

  # An oversize row is skipped by next_offset, so paging never stops dead.
  defp maybe_put_next(result, :big_row, _keep, offset),
    do: Map.put(result, "next_offset", offset + 1)

  defp maybe_put_next(result, :small_cap, _keep, _offset), do: result

  defp maybe_put_next(result, :cut, keep, offset),
    do: Map.put(result, "next_offset", offset + keep)

  defp reserve(hint), do: byte_size(hint) + 60

  defp rows_hint(:big_row, name, _keep, _total, cap, offset) do
    "the row at offset #{offset} is larger than the cap of #{cap} bytes: pass max_bytes " <>
      "(max_bytes: 0 for no cap, the result may then exceed the client's tool result limit: " <>
      "write it to a file with curl) to read it, or offset: #{offset + 1} to skip it" <>
      narrowing(name, ";") <> "."
  end

  defp rows_hint(:small_cap, _name, _keep, _total, cap, _offset) do
    "the cap of #{cap} bytes is too small for this result's fixed fields. " <>
      "Pass max_bytes with a larger value (or max_bytes: 0 for no cap)."
  end

  defp rows_hint(:cut, name, keep, total, cap, offset) do
    "result cut to #{keep} of the #{total} rows of this call to stay under #{cap} bytes. " <>
      "For the rest call again with offset: #{offset + keep}; for everything in one result " <>
      "pass max_bytes (or max_bytes: 0 for no cap, the result may then exceed the client's " <>
      "tool result limit: write it to a file with curl)" <> narrowing(name, ";") <> "."
  end

  # The arguments each tool accepts to return less; never one it rejects.
  @narrowing %{
    "list_pages" => ["filters", "a lower limit", "without verbose"],
    "page_queries" => ["filters", "group_by", "a lower limit", "without verbose"],
    "page_callbacks" => ["filters", "a lower limit"],
    "page_errors" => ["a lower limit"],
    "recent_errors" => ["a lower limit"]
  }

  defp narrowing(name, lead) do
    case Map.get(@narrowing, name, []) do
      [] -> ""
      options -> "#{lead} or narrow it with #{Enum.join(options, ", ")}"
    end
  end

  # Tools without rows (page_summary, compare_pages, page_n_plus_one): the
  # longest list goes first, from its end.

  defp cut_nested(name, result, size, cap) do
    hint = nested_hint(name, cap)
    target = size - cap + reserve(hint)
    {result, left} = trim(result, target)

    case left < target do
      true -> result |> Map.put("truncated", true) |> Map.put("hint", hint)
      false -> result
    end
  end

  defp trim(result, target) when target <= 0, do: {result, target}

  defp trim(result, target) do
    case longest_list(result) do
      nil ->
        {result, target}

      {path, list} ->
        {kept, freed} = drop_from_end(list, target)
        trim(put_in_path(result, path, kept), target - freed)
    end
  end

  # Drops elements from the end until `target` bytes are freed (or none is left).
  defp drop_from_end(list, target) do
    {dropped, freed} =
      list
      |> Enum.reverse()
      |> Enum.reduce_while({0, 0}, fn item, {dropped, freed} ->
        case freed >= target do
          true -> {:halt, {dropped, freed}}
          false -> {:cont, {dropped + 1, freed + byte_size(Json.encode!(item)) + 1}}
        end
      end)

    {Enum.take(list, length(list) - dropped), freed}
  end

  defp longest_list(term), do: longest_list(term, [], 0, nil)

  defp longest_list(map, path, depth, best) when is_map(map) and depth < 4 do
    Enum.reduce(map, best, fn {key, value}, acc ->
      longest_list(value, [key | path], depth + 1, acc)
    end)
  end

  defp longest_list([_ | _] = list, path, depth, best) when depth < 4 do
    case best do
      {_path, current} when length(current) >= length(list) -> best
      _shorter -> {Enum.reverse(path), list}
    end
  end

  defp longest_list(_term, _path, _depth, best), do: best

  defp put_in_path(map, [key], value), do: Map.put(map, key, value)

  defp put_in_path(map, [key | rest], value),
    do: Map.put(map, key, put_in_path(Map.fetch!(map, key), rest, value))

  defp nested_hint("page_summary", cap) do
    "result cut to stay under #{cap} bytes: lists were shortened, longest first. " <>
      "Use page_queries, page_callbacks and page_errors for the full lists; " <>
      "or pass max_bytes (max_bytes: 0 for no cap, the result may then exceed the client's " <>
      "tool result limit: write it to a file with curl)."
  end

  defp nested_hint(_name, cap) do
    "result cut to stay under #{cap} bytes: lists were shortened, longest first. " <>
      "Pass max_bytes (max_bytes: 0 for no cap, the result may then exceed the client's tool " <>
      "result limit: write it to a file with curl) for the full result, or use page_queries, " <>
      "page_callbacks and page_errors for details."
  end

  # page_report

  defp cut_markdown(result, markdown, cap) do
    {body, footer} = split_footer(markdown)

    closing =
      "\n\n_Report cut to stay under #{cap} bytes: pass max_bytes (max_bytes: 0 for no cap) " <>
        "for all of it, or use the page_* tools (page_queries, page_callbacks, page_errors)._\n"

    room = max(cap - byte_size(closing) - byte_size(footer), 0)

    result
    |> Map.put("markdown", utf8_prefix(body, room) <> closing <> footer)
    |> Map.put("truncated", true)
    |> Map.put(
      "hint",
      "report cut to stay under #{cap} bytes. Pass max_bytes (max_bytes: 0 for no cap, the result " <>
        "may then exceed the client's tool result limit: write it to a file with curl) for all of it, " <>
        "or use page_queries, page_callbacks and page_errors."
    )
  end

  defp split_footer(markdown) do
    case :binary.matches(markdown, @footer_marker) do
      [] ->
        {markdown, ""}

      matches ->
        {at, _length} = List.last(matches)
        {binary_part(markdown, 0, at), binary_part(markdown, at, byte_size(markdown) - at)}
    end
  end

  # At most `room` bytes of `binary`, never splitting a UTF-8 character.
  defp utf8_prefix(binary, room) when byte_size(binary) <= room, do: binary

  defp utf8_prefix(binary, room) do
    prefix = binary_part(binary, 0, room)

    case String.valid?(prefix) do
      true -> prefix
      false -> utf8_prefix(binary, room - 1)
    end
  end
end
