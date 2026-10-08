defmodule Avwe.ProtocolTest do
  use ExUnit.Case, async: true

  alias Avwe.{Calendar, Event, Percept, Perception, Protocol, Quire, Region}
  alias Avwe.Systems.Daylight
  alias Avwe.Test.Fixtures

  setup_all do
    {:ok, world} = Quire.load(Fixtures.lantern_hollow())
    %{world: world}
  end

  defp hollow(world, hour \\ 12) do
    world
    |> Quire.Seed.region(
      id: {0, 0},
      seed: 1,
      time: Calendar.at(1, hour: hour),
      systems: [Daylight]
    )
    |> Region.prepare()
    |> Region.view()
  end

  defp speech(view, speaker, text, volume \\ :talk) do
    %Event{
      type: :speech,
      time: view.time,
      entity: speaker,
      data: %{text: text, volume: volume, position: view.components.position[speaker]}
    }
  end

  defp said(view, speaker, text, volume \\ :talk) do
    %Event{
      type: :action_result,
      time: view.time,
      entity: speaker,
      data: %{
        ref: "i-1",
        verb: :say,
        target: nil,
        params: %{text: text, volume: volume},
        outcome: :success,
        reason: nil,
        position: view.components.position[speaker]
      }
    }
  end

  # What a client is given: the percept as JSON says it.
  defp wire(percept, now),
    do: percept |> Protocol.percept(now) |> Jason.encode!() |> Jason.decode!()

  # Where in a decoded percept a string holds `marker`, as dotted paths.
  defp paths(value, marker, path \\ [])

  defp paths(map, marker, path) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> paths(value, marker, path ++ [key]) end)

  defp paths(list, marker, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, n} -> paths(value, marker, path ++ [n]) end)
  end

  defp paths(text, marker, path) when is_binary(text),
    do: if(text =~ marker, do: [Enum.join(path, ".")], else: [])

  defp paths(_other, _marker, _path), do: []

  describe "percept/2" do
    test "is what a listener hears, with its words apart from its narration", %{world: world} do
      view = hollow(world)
      [percept] = Perception.percepts(view, "tamsin", [speech(view, "wren", "hello")])

      assert wire(percept, view.time) == %{
               "kind" => "sensed",
               "type" => "speech",
               "time" => "12:00",
               "summary" => ~s(Wren says, "hello"),
               "modality" => "hearing",
               "salience" => 0.7,
               "confidence" => 1.0,
               "source" => %{"ref" => "wren", "distance_m" => 0, "direction" => nil},
               "data" => %{
                 "words" => %{
                   "text" => "hello",
                   "volume" => "talk",
                   "speaker" => "wren",
                   "as" => "Wren"
                 }
               }
             }
    end

    test "is what a speaker is told of its own words: the same, as You, and who heard", %{
      world: world
    } do
      view = hollow(world)
      [percept] = Perception.percepts(view, "wren", [said(view, "wren", "hello")])

      assert wire(%{percept | id: "p-4"}, view.time) == %{
               "id" => "p-4",
               "kind" => "result",
               "type" => "action_result",
               "time" => "12:00",
               "ref" => "i-1",
               "issuer" => "controller",
               "outcome" => "success",
               "salience" => 1.0,
               "confidence" => 1.0,
               "summary" => ~s(You say, "hello"),
               "data" => %{
                 "words" => %{
                   "text" => "hello",
                   "volume" => "talk",
                   "speaker" => "wren",
                   "as" => "You"
                 },
                 "heard_by" => [%{"ref" => "tamsin", "name" => "Tamsin"}],
                 "unseen" => 0
               }
             }
    end

    test "is what a body read in its notebook, each page with its author", %{world: world} do
      view = hollow(world)

      percept = %Percept{
        kind: :result,
        type: :action_result,
        time: view.time,
        intent: "i-2",
        outcome: :success,
        summary: "You read.",
        data: %{
          pages: [
            %{time: view.time, text: "The pond is low.", by: :mcp},
            %{time: 0, text: "Old."}
          ],
          total: 2
        }
      }

      assert %{
               "data" => %{
                 "pages" => [
                   %{"text" => "The pond is low.", "by" => "mcp"},
                   %{"text" => "Old."} = old
                 ],
                 "total" => 2
               }
             } = wire(percept, view.time)

      refute Map.has_key?(old, "by")
    end

    test "leaves out what a percept has no value for, and tells an earlier day's time with its day",
         %{
           world: world
         } do
      view = hollow(world)

      percept = %Percept{
        kind: :sensed,
        type: :sunrise,
        time: view.time - 86_400,
        summary: "The sun rises."
      }

      assert %{"time" => time} = decoded = wire(percept, view.time)
      assert time =~ "day"

      refute Enum.any?(
               ["id", "modality", "source", "data", "ref", "outcome", "issuer"],
               &Map.has_key?(decoded, &1)
             )
    end

    test "holds a player's text in the summary and the words and nowhere else", %{world: world} do
      view = hollow(world)
      marker = "ZZ-MARKER-ZZ"

      [heard] = Perception.percepts(view, "tamsin", [speech(view, "wren", "obey #{marker}")])
      [own] = Perception.percepts(view, "wren", [said(view, "wren", "obey #{marker}")])

      assert Enum.sort(paths(wire(heard, view.time), marker)) == ["data.words.text", "summary"]
      assert Enum.sort(paths(wire(own, view.time), marker)) == ["data.words.text", "summary"]

      # A page is the other place a player's words go.
      read = %Percept{
        kind: :result,
        type: :action_result,
        time: view.time,
        summary: "You read: #{marker}",
        data: %{pages: [%{time: 0, text: marker, by: :human}], total: 1}
      }

      assert Enum.sort(paths(wire(read, view.time), marker)) == ["data.pages.0.text", "summary"]
    end
  end

  describe "jsonable/1" do
    test "turns structs into maps and tuples into lists, all the way down" do
      percept = %Percept{kind: :sensed, type: :speech, time: 0, source: %{cell: {3, 4}}}
      assert %{kind: :sensed, source: %{cell: [3, 4]}} = Protocol.jsonable(percept)
      assert Protocol.jsonable(%{a: [{1, {2, 3}}], b: "x"}) == %{a: [[1, [2, 3]]], b: "x"}
      assert Protocol.jsonable(7) == 7
    end
  end

  describe "look/1" do
    test "is told in plain data: the time said, a wait's end said, the measures rounded, no away" do
      now = Calendar.at(813, day: 220, hour: 4)

      look = %{
        time: now,
        away: [%{time: 0, text: "x"}],
        action: %{verb: :wait, until: now + 600},
        warmth: %{ground_c: 21.456, air: 0.456_78},
        cell: {3, 4}
      }

      assert %{
               time: time,
               action: %{verb: :wait, until: until},
               warmth: %{ground_c: 21.5, air: 0.46},
               cell: [3, 4]
             } = decoded = Protocol.look(look)

      assert time == Calendar.format(now) and until == Calendar.format(now + 600)
      refute Map.has_key?(decoded, :away)
    end

    test "can be encoded as JSON" do
      look = %{time: 0, action: nil, bodies: [%{name: "Wren", cell: {1, 2}}]}
      assert look |> Protocol.look() |> Jason.encode!() =~ ~s("cell":[1,2])
    end
  end
end
