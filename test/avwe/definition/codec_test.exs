defmodule Avwe.Definition.CodecTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.Definition.Codec

  defp decode(type, json), do: Codec.decode(type, json, "")

  defp problems(type, json) do
    assert {:error, problems} = decode(type, json)
    problems
  end

  describe "scalars" do
    test "a string, a whole number and a number are what they say" do
      assert decode(:string, "a") == {:ok, "a"}
      assert decode(:integer, 3) == {:ok, 3}
      assert decode(:number, 3) == {:ok, 3}
      assert decode(:number, 3.5) == {:ok, 3.5}

      assert problems(:string, 3) == ["the file: expected a string, got 3"]
      assert problems(:integer, 3.5) == ["the file: expected a whole number, got 3.5"]
      assert problems(:number, "3") == [~s(the file: expected a number, got "3")]
    end

    test "a number keeps being the integer or the float it was written as" do
      assert {:ok, 8} = decode(:number, 8)
      assert {:ok, 8.0} = decode(:number, 8.0)
      assert Codec.encode(:number, 8) === 8
      assert Codec.encode(:number, 8.0) === 8.0
    end

    test "a float is read from any number and written only from a float" do
      assert decode(:float, 8) === {:ok, 8.0}
      assert decode(:float, 8.5) === {:ok, 8.5}
      assert Codec.encode(:float, 8.0) === 8.0

      error = assert_raise ArgumentError, fn -> Codec.encode(:float, 8) end
      assert error.message =~ "cannot write 8 as a number"
    end

    test "null is a value only where the type allows it" do
      assert decode({:nullable, :string}, nil) == {:ok, nil}
      assert decode({:nullable, :string}, "a") == {:ok, "a"}
      assert problems({:nullable, :string}, 3) == ["the file: expected a string, got 3"]
      assert problems(:string, nil) == ["the file: expected a string, got nil"]
      assert Codec.encode({:nullable, :string}, nil) == nil
    end

    test "a value must also satisfy the condition of its type, which says what it wanted" do
      type = {:where, :integer, &(&1 > 0), "a whole number above 0"}

      assert decode(type, 2) == {:ok, 2}
      assert problems(type, 0) == ["the file: expected a whole number above 0, got 0"]
      assert problems(type, "2") == ["the file: expected a whole number, got \"2\""]
      assert Codec.encode(type, 2) == 2
    end
  end

  describe "names" do
    @allowed [:fuel, :dousing]

    test "a string is an atom only by being one of the names the type lists" do
      assert decode({:atom, @allowed}, "fuel") == {:ok, :fuel}
      assert decode({:atoms, @allowed}, ["dousing", "fuel"]) == {:ok, [:dousing, :fuel]}

      assert problems({:atom, @allowed}, "water") ==
               [~s(the file: expected one of "fuel", "dousing", got "water")]

      assert problems({:atoms, @allowed}, ["fuel", "water"]) ==
               [~s([1]: expected one of "fuel", "dousing", got "water")]
    end

    test "no atom is made from what a file says" do
      name = "never_an_atom_#{System.unique_integer([:positive])}"

      for type <- [
            {:atom, @allowed},
            {:atoms, @allowed},
            {:keyword, [fuel: {:opt, :string}]},
            {:atom_map, @allowed, :number},
            {:tagged, :kind, fuel: {:keyword, [kind: {:atom, [:fuel]}]}},
            :params,
            :step
          ] do
        json = if type in [:params, :step], do: %{name => 1}, else: %{name => name}
        assert {:error, _problems} = decode(type, json)
        assert {:error, _problems} = decode(type, [name])
      end

      assert {:error, _problems} = decode(:step, %{"verb" => name})
      assert {:error, _problems} = decode(:params, %{"for" => 1, name => 1})
      assert {:error, _problems} = decode({:keyed, :string}, %{name => 1})

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "writing refuses an atom the type does not list" do
      error = assert_raise ArgumentError, fn -> Codec.encode({:atom, @allowed}, :water) end
      assert error.message =~ ~s(:water is not one of "fuel", "dousing")
      assert Codec.encode({:atoms, @allowed}, [:fuel]) == ["fuel"]
    end
  end

  describe "lists, sets and objects" do
    test "a list is read item by item, and the path says which item" do
      assert decode({:list, :integer}, [1, 2]) == {:ok, [1, 2]}

      assert problems({:list, :integer}, [1, "b", 3, "d"]) ==
               [
                 ~s([1]: expected a whole number, got "b"),
                 ~s([3]: expected a whole number, got "d")
               ]

      assert problems({:list, :integer}, %{}) == ["the file: expected a list, got %{}"]
    end

    test "a set is a list read as a MapSet, and written in order" do
      assert decode({:set, :string}, ["b", "a", "b"]) == {:ok, MapSet.new(["a", "b"])}
      assert Codec.encode({:set, :string}, MapSet.new(["b", "a"])) == ["a", "b"]
    end

    test "a big set is written in order too, though a MapSet of that size keeps none" do
      ids = for n <- 1..80, do: "place-#{n}"

      assert Codec.encode({:set, :string}, MapSet.new(ids)) == Enum.sort(ids)
    end

    test "an object is read into a keyword list in the order of its fields" do
      type = {:keyword, [id: :string, size: {:opt, :integer}, tag: {:opt, {:nullable, :string}}]}

      assert decode(type, %{"tag" => nil, "id" => "x"}) == {:ok, [id: "x", tag: nil]}
      assert decode(type, %{"size" => 2, "id" => "x"}) == {:ok, [id: "x", size: 2]}
    end

    test "an object is read into a map when the type says a map" do
      type = {:map, [id: :string, size: {:opt, :integer}]}

      assert decode(type, %{"id" => "x"}) == {:ok, %{id: "x"}}
      assert decode(type, %{"id" => "x", "size" => 2}) == {:ok, %{id: "x", size: 2}}
    end

    test "every problem in an object is reported, not the first, each with its path" do
      type =
        {:keyword,
         [
           id: :string,
           size: :integer,
           parts: {:list, {:keyword, [name: :string]}}
         ]}

      json = %{"id" => 1, "colour" => "red", "parts" => [%{"name" => "a"}, %{"name" => 2}, %{}]}

      assert problems(type, json) == [
               ~s|colour: not a key of this (it has "id", "size", "parts")|,
               "id: expected a string, got 1",
               "size: missing",
               "parts[1].name: expected a string, got 2",
               "parts[2].name: missing"
             ]
    end

    test "a path is written down from the top" do
      type = {:keyword, [a: {:keyword, [b: {:list, {:keyword, [c: :integer]}}]}]}
      json = %{"a" => %{"b" => [%{"c" => 1}, %{"c" => "x"}]}}

      assert problems(type, json) == [~s(a.b[1].c: expected a whole number, got "x")]
    end

    test "an object whose keys are anything is read as pairs, by key" do
      type = {:keyed, {:keyword, [n: :integer]}}

      assert decode(type, %{"b" => %{"n" => 2}, "a" => %{"n" => 1}}) ==
               {:ok, [{"a", [n: 1]}, {"b", [n: 2]}]}

      assert problems(type, %{"a" => %{"n" => "x"}}) == [
               ~s(["a"].n: expected a whole number, got "x")
             ]

      assert Codec.encode(type, [{"a", [n: 1]}]) == %{"a" => %{"n" => 1}}
    end

    test "writing refuses a key the type does not have, and a field it needs" do
      type = {:keyword, [id: :string, size: {:opt, :integer}]}

      assert Codec.encode(type, id: "x") == %{"id" => "x"}
      assert Codec.encode(type, id: "x", size: 2) == %{"id" => "x", "size" => 2}

      error = assert_raise ArgumentError, fn -> Codec.encode(type, id: "x", colour: "red") end
      assert error.message =~ "cannot write the keys [:colour]"

      error = assert_raise ArgumentError, fn -> Codec.encode(type, size: 2) end
      assert error.message =~ "cannot write without :id"
    end

    test "a key that is present is written, null or not, and one that is absent is left out" do
      type = {:map, [id: :string, note: {:opt, {:nullable, :string}}]}

      assert Codec.encode(type, %{id: "x", note: nil}) == %{"id" => "x", "note" => nil}
      assert Codec.encode(type, %{id: "x"}) == %{"id" => "x"}

      error = assert_raise ArgumentError, fn -> Codec.encode(type, %{id: "x", note: 3}) end
      assert error.message =~ "cannot write 3 as a string"
    end
  end

  describe "the shapes of a world" do
    test "a cell is two whole numbers" do
      assert decode(:cell, [3, 4]) == {:ok, {3, 4}}
      assert Codec.encode(:cell, {3, 4}) == [3, 4]
      assert problems(:cell, [3]) == ["the file: expected a cell, [x, y], got [3]"]
      assert problems(:cell, [3, 4.5]) == ["the file: expected a cell, [x, y], got [3, 4.5]"]
    end

    test "a range goes up" do
      assert decode(:range, [20, 70]) == {:ok, 20..70}
      assert Codec.encode(:range, 20..70) == [20, 70]
      assert [problem] = problems(:range, [70, 20])
      assert problem =~ "two whole numbers, [first, last], going up"
    end

    test "a waypoint is a place, or a place beside which the river passes" do
      assert decode(:waypoint, "the-bend") == {:ok, "the-bend"}

      assert decode(:waypoint, %{"place" => "town", "beside" => "east", "cells" => 6}) ==
               {:ok, {"town", beside: :east, cells: 6}}

      assert Codec.encode(:waypoint, {"town", beside: :east, cells: 6}) ==
               %{"place" => "town", "beside" => "east", "cells" => 6}

      assert [problem] = problems(:waypoint, %{"place" => "town", "beside" => "up", "cells" => 6})
      assert problem =~ ~s(beside: expected one of "north", "east", "south", "west", got "up")
    end

    test "an entry about a place is the place and its options" do
      type = {:place_entry, [height_m: :number, radius_cells: :integer]}
      json = %{"place" => "lodge", "height_m" => 14, "radius_cells" => 18}

      assert decode(type, json) == {:ok, {"lodge", height_m: 14, radius_cells: 18}}
      assert Codec.encode(type, {"lodge", height_m: 14, radius_cells: 18}) == json
    end

    test "a time is seconds, or a date with the day and the hour on the clock" do
      assert decode(:calendar_time, 120) == {:ok, 120}

      assert decode(:calendar_time, %{"year" => 813, "day" => 220, "hour" => 4}) ==
               {:ok, {813, day: 220, hour: 4}}

      assert decode(:calendar_time, %{"year" => 1}) == {:ok, {1, []}}

      assert Codec.encode(:calendar_time, {813, day: 220, hour: 4}) ==
               %{"year" => 813, "day" => 220, "hour" => 4}

      assert Codec.encode(:calendar_time, 120) == 120

      assert problems(:calendar_time, %{"year" => 813, "day" => 0, "hour" => 24, "minute" => 60}) ==
               [
                 "day: expected a day of the year, 1 or more, got 0",
                 "hour: expected an hour, 0 to 23, got 24",
                 "minute: expected a minute, 0 to 59, got 60"
               ]
    end

    test "a name-keyed object of one kind of value is read into a map" do
      type = {:atom_map, [:flow_m3_s, :temp_c], :float}

      assert decode(type, %{"flow_m3_s" => 0}) === {:ok, %{flow_m3_s: 0.0}}

      assert problems(type, %{"flow_m3_s" => 0, "depth" => 1, "temp_c" => "hot"}) == [
               ~s(depth: not one of "flow_m3_s", "temp_c"),
               ~s(temp_c: expected a number, got "hot")
             ]

      assert Codec.encode(type, %{temp_c: 40.0}) == %{"temp_c" => 40.0}
    end

    test "an object of one of several kinds is read as the kind it names" do
      type =
        {:tagged, :kind,
         [
           event: {:keyword, [kind: {:atom, [:event]}, at: :integer]},
           standing: {:keyword, [kind: {:atom, [:standing]}, heat: :float]}
         ]}

      assert decode(type, %{"kind" => "event", "at" => 3}) == {:ok, [kind: :event, at: 3]}

      assert decode(type, %{"kind" => "standing", "heat" => 8}) ==
               {:ok, [kind: :standing, heat: 8.0]}

      assert problems(type, %{"kind" => "other"}) == [
               ~s(kind: expected one of "event", "standing", got "other")
             ]

      assert problems(type, %{"at" => 3}) == [
               "kind: expected one of \"event\", \"standing\", got nil"
             ]

      assert problems(type, %{"kind" => "event"}) == ["at: missing"]
      assert [problem] = problems(type, %{"kind" => "event", "at" => 3, "heat" => 1.0})
      assert problem =~ "heat: not a key of this"

      assert Codec.encode(type, kind: :standing, heat: 8.0) == %{
               "kind" => "standing",
               "heat" => 8.0
             }

      error = assert_raise ArgumentError, fn -> Codec.encode(type, kind: :other) end
      assert error.message =~ "cannot write :kind :other"
    end
  end

  describe "a step of a plan" do
    test "is a verb, and what it acts on, and its parameters" do
      assert decode(:step, %{"verb" => "rest"}) == {:ok, {:rest}}
      assert decode(:step, %{"verb" => "go", "target" => "bend"}) == {:ok, {:go, target: "bend"}}

      assert decode(:step, %{"verb" => "wait", "params" => %{"for" => 2400}}) ==
               {:ok, {:wait, params: %{for: 2400}}}

      assert decode(:step, %{
               "verb" => "say",
               "target" => "x",
               "params" => %{"volume" => "shout", "text" => "hi"}
             }) ==
               {:ok, {:say, target: "x", params: %{volume: :shout, text: "hi"}}}
    end

    test "is written back the same, and only in the order target then params" do
      for step <- [
            {:rest},
            {:go, target: "bend"},
            {:wait, params: %{for: 2400}},
            {:wait, params: %{until: :dusk}},
            {:follow, params: %{direction: :upstream}},
            {:walk, params: %{direction: "south", distance_m: 200}},
            {:say, target: "x", params: %{volume: :whisper, text: "hi"}}
          ] do
        assert {:ok, ^step} = step |> then(&Codec.encode(:step, &1)) |> then(&decode(:step, &1))
      end

      error =
        assert_raise ArgumentError, fn ->
          Codec.encode(:step, {:say, params: %{text: "hi"}, target: "x"})
        end

      assert error.message =~ "a step can carry target and then params"
    end

    test "is refused for a verb or a parameter the engine has not been taught" do
      assert problems(:step, %{"verb" => "fly"}) |> hd() =~ ~s(verb: expected one of "go")
      assert problems(:step, %{"verb" => "go", "tool" => "x"}) |> hd() =~ "tool: not a key"

      assert problems(:step, %{"verb" => "wait", "params" => %{"speed" => 1}}) |> hd() =~
               ~s(params.speed: not one of "for")

      assert problems(:step, %{"verb" => "wait", "params" => %{"until" => "noon"}}) |> hd() =~
               ~s(params.until: expected one of "dawn", "dusk")

      assert problems(:step, %{"verb" => "wait", "params" => %{"for" => "long"}}) ==
               [~s(params.for: expected a number, got "long")]
    end

    test "a plan is a list of steps, at least one" do
      assert decode(:plan, [%{"verb" => "go", "target" => "a"}, %{"verb" => "rest"}]) ==
               {:ok, [{:go, target: "a"}, {:rest}]}

      assert problems(:plan, []) == ["the file: expected a list of steps, at least one, got []"]

      assert problems(:plan, [%{"verb" => "go"}, %{"verb" => "dance"}]) |> hd() =~
               "[1].verb: expected one of"

      assert Codec.encode(:plan, [{:go, target: "a"}, {:rest}]) ==
               [%{"verb" => "go", "target" => "a"}, %{"verb" => "rest"}]
    end
  end

  describe "round trips" do
    property "a cell, a range and a calendar time come back as they went" do
      check all x <- integer(-1000..1000),
                y <- integer(-1000..1000),
                first <- integer(-50..50),
                span <- integer(0..50),
                year <- integer(0..2000),
                day <- integer(1..400),
                hour <- integer(0..23) do
        assert {:ok, {^x, ^y}} = :cell |> Codec.encode({x, y}) |> then(&decode(:cell, &1))

        range = first..(first + span)
        assert {:ok, ^range} = :range |> Codec.encode(range) |> then(&decode(:range, &1))

        time = {year, day: day, hour: hour}

        assert {:ok, ^time} =
                 :calendar_time |> Codec.encode(time) |> then(&decode(:calendar_time, &1))
      end
    end

    property "a string, even an odd one, comes back through JSON as it went" do
      check all text <- string(:printable) do
        json = text |> then(&Codec.encode(:string, &1)) |> JSON.encode!() |> JSON.decode!()
        assert decode(:string, json) == {:ok, text}
      end
    end
  end
end
