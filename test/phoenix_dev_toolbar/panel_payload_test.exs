defmodule PhoenixDevToolbar.PanelPayloadTest do
  # What the panel LiveView sends over its socket for a realistic capture
  # (ADR 04): measured as the JSON size of the channel messages it pushes.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import PhoenixDevToolbar.PageHelpers
  import PhoenixDevToolbar.ReportFixtures

  alias PhoenixDevToolbar.Store

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
    :ok
  end

  defp seed do
    request = session(:request, path: "/demo")
    live = session(:live_view, parent: request.sid, path: "/demo", view: DemoWeb.PageLive)

    trace =
      for n <- 1..12, do: "lib/demo/module_#{n}.ex:#{n * 10}: Demo.Module#{n}.function_#{n}/2"

    for n <- 1..40,
        do: query(live, sql: "SELECT * FROM table_#{n} WHERE id = ?", stacktrace: trace)

    for n <- 1..30, do: callback(live, :handle_event, event: "event_#{n}")
    {request, live}
  end

  # Bytes of the diffs and replies the traced processes pushed, per process.
  defp trace_sends(fun) do
    :erlang.trace(:new_processes, true, [:send])

    try do
      result = fun.()
      {result, drain(%{})}
    after
      :erlang.trace(:new_processes, false, [:send])
    end
  end

  defp drain(acc) do
    receive do
      {:trace, pid, :send, msg, _to} -> drain(Map.update(acc, pid, size(msg), &(&1 + size(msg))))
    after
      50 -> acc
    end
  end

  defp size(%Phoenix.Socket.Reply{payload: payload}), do: json_size(payload)
  defp size(%Phoenix.Socket.Message{event: "diff", payload: payload}), do: json_size(payload)
  defp size(_other), do: 0

  defp json_size(term),
    do: term |> Phoenix.json_library().encode_to_iodata!() |> IO.iodata_length()

  # Before the lazy tabs (ADR 04) on this capture: mount 82385 B, 5 new events 7666 B.
  test "the panel pushes the open tab's rows only, on mount and on new events" do
    {request, live} = seed()

    {panel, sent} = trace_sends(fn -> open_panel(request.sid) end)
    mount_bytes = Map.fetch!(sent, panel.pid)

    {_, sent} =
      trace_sends(fn ->
        for n <- 1..5, do: callback(live, :handle_event, event: "new_#{n}")
        flush(panel)
      end)

    event_bytes = Map.get(sent, panel.pid, 0)
    IO.puts("panel payload: mount #{mount_bytes} B, 5 new events #{event_bytes} B")

    # The open (Ecto) tab's 40 collapsed rows (no details) are the mount: 60 KB with inline details.
    assert mount_bytes < 36_000
    assert event_bytes < 1_500
  end

  test "a hidden tab gets no rows until it is opened" do
    {request, live} = seed()
    panel = open_panel(request.sid)

    refute has_element?(panel, "#pdt-lv-log li[id^=pdt-lv-][data-pdt-row]")
    callback(live, :handle_event, event: "late")
    flush(panel)
    refute has_element?(panel, "#pdt-lv-log li[id^=pdt-lv-][data-pdt-row]")
    assert has_element?(panel, "#pdt-queries li[id^=pdt-query-]")

    open_panel_tab(panel, "live_view")
    assert has_element?(panel, "#pdt-lv-log li[id^=pdt-lv-][data-pdt-row]")

    callback(live, :handle_event, event: "after")
    flush(panel)
    assert has_element?(panel, "#pdt-lv-log li[id^=pdt-lv-][data-pdt-row]", "after")
  end
end
