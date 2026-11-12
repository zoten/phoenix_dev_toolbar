defmodule PhoenixDevToolbar.InspectedTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.Inspected

  @payload %{
    "root" => "phx-F1",
    "cid" => 3,
    "tag" => "button",
    "tag_line" => 7,
    "binding" => %{"event" => "phx-click", "name" => "save", "target" => nil},
    "frames" => [%{"name" => "Demo.Core.button", "file" => "lib/x.ex", "line" => 12}],
    "caller" => %{"file" => "lib/y.ex", "line" => 34}
  }

  describe "parse/1" do
    test "reads the loader's payload into a struct" do
      assert {:ok,
              %Inspected{
                root: "phx-F1",
                cid: 3,
                tag: "button",
                tag_line: 7,
                binding: %{event: "phx-click", name: "save", target: nil},
                frames: [%{name: "Demo.Core.button", file: "lib/x.ex", line: 12}],
                caller: %{file: "lib/y.ex", line: 34}
              }} = Inspected.parse(@payload)
    end

    test "a dead render has no root, cid, binding or frames" do
      assert {:ok, %Inspected{root: nil, cid: nil, binding: nil, frames: [], caller: nil}} =
               Inspected.parse(%{"root" => nil, "tag" => "p", "frames" => []})
    end

    test "caps strings at 512 bytes on a character boundary" do
      long = String.duplicate("é", 400)

      assert {:ok, %Inspected{tag: tag}} = Inspected.parse(%{@payload | "tag" => long})
      assert byte_size(tag) <= 512
      assert String.valid?(tag)
    end

    test "caps frames at 20 and keeps integers in range" do
      frame = %{"name" => "A.b", "file" => "lib/a.ex", "line" => 1}

      assert {:ok, %Inspected{frames: frames}} =
               Inspected.parse(%{@payload | "frames" => List.duplicate(frame, 50)})

      assert length(frames) == 20

      for bad <- [-1, 10_000_001, "7", 1.5, nil, %{}] do
        assert {:ok, %Inspected{cid: nil, tag_line: nil}} =
                 Inspected.parse(%{@payload | "cid" => bad, "tag_line" => bad})
      end
    end

    test "drops invalid fields instead of raising" do
      garbage = %{
        "root" => 5,
        "tag" => <<255, 254>>,
        "binding" => %{"event" => "phx-hack", "name" => "x"},
        "frames" => [1, %{"name" => 2}, %{"file" => "lib/a.ex"}, "x"],
        "caller" => ["lib/y.ex"]
      }

      assert {:ok, %Inspected{root: nil, tag: nil, binding: nil, frames: [], caller: nil}} =
               Inspected.parse(garbage)

      assert Inspected.parse("nope") == :error
      assert Inspected.parse(nil) == :error
      assert Inspected.parse([]) == :error
    end

    test "never creates atoms from the payload" do
      key = "pdt_never_an_atom_#{System.unique_integer([:positive])}"
      Inspected.parse(Map.put(@payload, key, "x"))

      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end
  end

  describe "editor_url/2" do
    @template "vscode://file/__FILE__:__LINE__"
    @frame %{file: "lib/x.ex", line: 12}

    test "fills the absolute file and the line" do
      assert Inspected.editor_url(@frame, @template) ==
               "vscode://file/#{File.cwd!()}/lib/x.ex:12"
    end

    test "no link without a template or with a scheme that is not letters and ://" do
      assert Inspected.editor_url(@frame, nil) == nil
      assert Inspected.editor_url(@frame, "") == nil
      assert Inspected.editor_url(@frame, "javascript:alert(1)//__FILE__") == nil
      assert Inspected.editor_url(@frame, "javascript://__FILE__") =~ "javascript://"
      assert Inspected.editor_url(@frame, "//evil/__FILE__") == nil
      assert Inspected.editor_url(@frame, "1ab://__FILE__") == nil
    end

    test "only relative files without .. segments" do
      for file <- ["/etc/passwd", "../x.ex", "lib/../../x.ex", "", "a\0b"] do
        assert Inspected.editor_url(%{file: file, line: 1}, @template) == nil
      end

      assert Inspected.editor_url(%{file: nil, line: 1}, @template) == nil
    end

    test "a missing line opens line 1; spaces are escaped" do
      assert Inspected.editor_url(%{file: "lib/a b.ex", line: nil}, @template) ==
               "vscode://file/#{File.cwd!()}/lib/a%20b.ex:1"
    end
  end
end
