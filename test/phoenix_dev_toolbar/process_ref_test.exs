defmodule PhoenixDevToolbar.ProcessRefTest do
  use ExUnit.Case, async: true

  import PhoenixDevToolbar.ProcessHelpers

  alias PhoenixDevToolbar.ProcessRef

  describe "parse/1 with a pid" do
    test "reads the inspect form, with or without brackets and spaces" do
      pid = idle_process()
      "#PID" <> text = inspect(pid)

      assert ProcessRef.parse(text) == {:ok, pid}
      assert ProcessRef.parse(String.trim(text, "<") |> String.trim(">")) == {:ok, pid}
      assert ProcessRef.parse("  #{text}\n") == {:ok, pid}
    end

    test "refuses an exited process" do
      pid = idle_process()
      "#PID" <> text = inspect(pid)
      stop(pid)

      assert ProcessRef.parse(text) == {:error, :dead}
    end

    test "refuses malformed pids" do
      assert ProcessRef.parse("<0.1>") == {:error, :not_found}
      assert ProcessRef.parse("<0.99999999999999999999.0>") == {:error, :invalid}
      assert ProcessRef.parse("<0.#{String.duplicate("9", 120)}.0>") == {:error, :invalid}
    end

    test "refuses a node index that names no known node" do
      assert ProcessRef.parse("<5.1.0>") == {:error, :invalid}
    end
  end

  describe "parse/1 with a registered name" do
    test "matches Erlang and Elixir spellings" do
      code_server = Process.whereis(:code_server)
      store = Process.whereis(PhoenixDevToolbar.Store)

      assert ProcessRef.parse("code_server") == {:ok, code_server}
      assert ProcessRef.parse(":code_server") == {:ok, code_server}
      assert ProcessRef.parse("PhoenixDevToolbar.Store") == {:ok, store}
      assert ProcessRef.parse("Elixir.PhoenixDevToolbar.Store") == {:ok, store}
    end

    test "an unknown name is not found and creates no atom" do
      name = "pdt_never_an_atom_#{System.unique_integer([:positive])}"

      assert ProcessRef.parse(name) == {:error, :not_found}
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  test "refuses empty, oversized and non string input" do
    assert ProcessRef.parse("") == {:error, :invalid}
    assert ProcessRef.parse("   ") == {:error, :invalid}
    assert ProcessRef.parse(String.duplicate("a", 129)) == {:error, :invalid}
    assert ProcessRef.parse(nil) == {:error, :invalid}
  end
end
