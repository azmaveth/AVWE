defmodule Avwe.Definition.JsonTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.Definition.Json

  describe "compact/1" do
    test "is the canonical text: keys in order, no spaces" do
      data = %{"b" => 1, "a" => [1, %{"d" => 2, "c" => [nil, true, "x"]}], "aa" => 2.5}

      assert Json.compact(data) == ~s({"a":[1,{"c":[null,true,"x"],"d":2}],"aa":2.5,"b":1})
    end

    test "sorts keys that are not the order a big map would give them" do
      data = Map.new(1..60, fn n -> {"k#{n}", n} end)
      keys = data |> Json.compact() |> JSON.decode!() |> Map.keys()
      sorted = data |> Map.keys() |> Enum.sort()

      assert Regex.scan(~r/"(k\d+)":/, Json.compact(data), capture: :all_but_first) ==
               Enum.map(sorted, &[&1])

      assert Enum.sort(keys) == sorted
    end

    test "writes strings as JSON does, and an empty object and list" do
      assert Json.compact(%{"s" => "a \"quoted\"\nline — é", "o" => %{}, "l" => []}) ==
               ~s({"l":[],"o":{},"s":"a \\"quoted\\"\\nline — é"})
    end
  end

  describe "pretty/1" do
    test "puts the keys that name a thing first, then the rest in order, a key to a line" do
      data = %{"zeta" => 1, "name" => "N", "alpha" => 2, "id" => "I", "schema" => 1}

      assert Json.pretty(data) ==
               """
               {"schema": 1, "id": "I", "name": "N", "alpha": 2, "zeta": 1}
               """
    end

    test "leaves a short object on a line and breaks a long one" do
      long = String.duplicate("word ", 20)

      data = %{
        "id" => "x",
        "text" => long,
        "cell" => [1, 2],
        "date" => %{"year" => 1, "day" => 2}
      }

      text = Json.pretty(data)

      assert text ==
               """
               {
                 "id": "x",
                 "cell": [1, 2],
                 "date": {"year": 1, "day": 2},
                 "text": "#{long}"
               }
               """
    end

    test "breaks a list of long things one to a line, indented under its key" do
      items = for n <- 1..3, do: %{"id" => "item-#{n}", "text" => String.duplicate("x", 80)}
      text = Json.pretty(%{"items" => items})

      assert text =~ ~s(  "items": [\n    {\n      "id": "item-1",\n      "text": "xxxx)
      assert text =~ "\n    },\n    {\n      \"id\": \"item-2\""
      assert String.ends_with?(text, "    }\n  ]\n}\n")
    end

    test "writes a float with its point, in full while it is short" do
      text =
        Json.pretty(%{
          "a" => 5000.0,
          "b" => 0.5,
          "c" => 1.0e-5,
          "d" => 8,
          "e" => 1.0e20,
          "f" => -2.0
        })

      assert text == ~s({"a": 5000.0, "b": 0.5, "c": 1.0e-5, "d": 8, "e": 1.0e20, "f": -2.0}\n)

      assert JSON.decode!(text) == %{
               "a" => 5000.0,
               "b" => 0.5,
               "c" => 1.0e-5,
               "d" => 8,
               "e" => 1.0e20,
               "f" => -2.0
             }
    end

    test "ends in a newline, and says what an empty object or list is" do
      assert Json.pretty(%{}) == "{}\n"
      assert Json.pretty([]) == "[]\n"
    end
  end

  describe "both forms" do
    defp tree do
      scalar = one_of([integer(), string(:printable), float(), boolean(), constant(nil)])

      tree(scalar, fn child ->
        one_of([
          list_of(child, max_length: 4),
          map_of(string(:alphanumeric, min_length: 1), child, max_length: 4)
        ])
      end)
    end

    property "read back as the data they were written from" do
      check all data <- tree() do
        assert data |> Json.compact() |> JSON.decode!() == data
        assert data |> Json.pretty() |> JSON.decode!() == data
      end
    end

    property "never put a line past the width unless it is one value that cannot be broken" do
      leaf = ~r/\A\s*("[^"\\]*": )?("(\\.|[^"\\])*"|-?[\d.eE+-]+|true|false|null),?\z/

      check all data <- tree() do
        for line <- data |> Json.pretty() |> String.split("\n"), String.length(line) > 88 do
          assert line =~ leaf
        end
      end
    end
  end
end
