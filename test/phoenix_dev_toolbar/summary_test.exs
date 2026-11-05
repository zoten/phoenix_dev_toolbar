defmodule PhoenixDevToolbar.SummaryTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.Event
  alias PhoenixDevToolbar.Summary

  doctest Summary

  test "counts failed queries, router exceptions and keeps the last response" do
    failed = Event.new(:ecto, :query, %{result: {:error, "boom"}}, at: 0)
    exception = Event.new(:request, :exception, %{}, at: 0)
    response = %{Event.new(:request, :response, %{status: 404}, at: 0) | duration: 900}

    summary = Summary.new([failed, exception, response])

    assert %Summary{queries: 1, failed_queries: 1, errors: 1} = summary
    assert summary.response == %{status: 404, duration: 900}
  end

  test "counts LiveView callbacks and keeps the slowest" do
    callback = Event.new(:live_view, :callback, %{callback: :handle_event}, at: 0)
    render = %{Event.new(:live_view, :render, %{}, at: 0) | duration: 9000}

    summary = Summary.new([%{callback | duration: 300}, %{callback | duration: 700}, render])

    assert %Summary{callbacks: 2, slowest_callback_us: 700} = summary
  end
end
