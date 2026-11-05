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
end
