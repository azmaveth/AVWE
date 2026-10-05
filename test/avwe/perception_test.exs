defmodule Avwe.PerceptionTest do
  use ExUnit.Case, async: true

  alias Avwe.{Calendar, Event, Perception, Quire, Region}
  alias Avwe.Systems.Daylight
  alias Avwe.Test.Fixtures

  setup_all do
    {:ok, world} = Quire.load(Fixtures.lantern_hollow())
    %{world: world}
  end

  defp view(world, hour) do
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

  defp speech(view, speaker, volume, text \\ "hello") do
    position = view.components.position[speaker]

    %Event{
      type: :speech,
      time: view.time,
      entity: speaker,
      data: %{text: text, volume: volume, position: position}
    }
  end

  describe "look/2" do
    test "at noon, a body sees its neighbours and knows its places", %{world: world} do
      look = Perception.look(view(world, 12), "wren")

      assert look.here.name == "Hollow Green"
      assert look.here.description =~ "lanterns"

      assert [
               %{name: "Pell", here: false, distance_m: 70, direction: "east"},
               %{name: "Tamsin", here: true}
             ] = Enum.sort_by(look.bodies, & &1.name)

      assert [
               %{name: "Far Tower", distance_m: 1530, direction: "east"},
               %{name: "Mill Pond", distance_m: 70, direction: "east"}
             ] = look.places

      assert %{verb: :go, targets: ["far-tower", "mill-pond"]} in look.affordances
      refute Enum.any?(look.affordances, &(&1.verb == :stop))
    end

    test "at night, sight shrinks to 50 m", %{world: world} do
      look = Perception.look(view(world, 2), "wren")
      assert Enum.map(look.bodies, & &1.name) == ["Tamsin"]
    end

    test "a spectator sees every body and place", %{world: world} do
      look = Perception.look(view(world, 12), nil)

      assert look.spectator
      assert Enum.map(look.bodies, & &1.name) == ["Odo", "Pell", "Tamsin", "Wren"]
      assert %{name: "Odo", at: "Far Tower"} = hd(look.bodies)
      assert length(look.places) == 3
    end
  end

  describe "hearing" do
    test "talk carries 15 m: the green hears it, the pond doesn't", %{world: world} do
      view = view(world, 12)
      event = speech(view, "wren", :talk)

      assert [%{summary: ~s(Wren says, "hello"), modality: :hearing, source: %{ref: "wren"}}] =
               Perception.percepts(view, "tamsin", [event])

      assert Perception.percepts(view, "pell", [event]) == []
    end

    test "a shout carries 100 m and says where it came from", %{world: world} do
      view = view(world, 12)

      assert [%{summary: ~s(Wren shouts from the west, "hello"), confidence: 1.0}] =
               Perception.percepts(view, "pell", [speech(view, "wren", :shout)])

      assert Perception.percepts(view, "odo", [speech(view, "wren", :shout)]) == []
    end

    test "a shout heard in the dark comes from someone unseen", %{world: world} do
      view = view(world, 2)

      assert [%{summary: ~s(Someone shouts from the west, "hello"), confidence: 0.6}] =
               Perception.percepts(view, "pell", [speech(view, "wren", :shout)])
    end

    test "a whisper only reaches the same spot", %{world: world} do
      view = view(world, 12)
      event = speech(view, "wren", :whisper)

      assert [%{summary: ~s(Wren whispers, "hello")}] =
               Perception.percepts(view, "tamsin", [event])

      assert Perception.percepts(view, "pell", [event]) == []
    end

    test "speakers don't hear themselves as someone else; spectators hear everyone", %{
      world: world
    } do
      view = view(world, 12)
      event = speech(view, "odo", :talk)

      assert Perception.percepts(view, "odo", [event]) == []
      assert [%{summary: ~s(Odo says, "hello")}] = Perception.percepts(view, nil, [event])
    end
  end

  describe "own actions" do
    test "results reach only the body that acted", %{world: world} do
      view = view(world, 12)

      result = %Event{
        type: :action_result,
        time: view.time,
        entity: "wren",
        data: %{
          ref: "i-1",
          verb: :go,
          target: "mill-pond",
          params: %{},
          outcome: :success,
          reason: :arrived
        }
      }

      assert [
               %{
                 kind: :result,
                 intent: "i-1",
                 outcome: :success,
                 summary: "You arrive at Mill Pond."
               }
             ] =
               Perception.percepts(view, "wren", [result])

      assert Perception.percepts(view, "tamsin", [result]) == []
      assert Perception.percepts(view, nil, [result]) == []
    end
  end

  describe "the river" do
    alias Avwe.{Prose, Terrain}
    alias Avwe.Test.Ember

    defp ember_view(at) do
      region = Ember.region(at)
      region |> Region.view() |> Map.put(:terrain, region.terrain)
    end

    test "from the town in 813, Mira sees the dry channel and which way is upstream" do
      look = Perception.look(ember_view({813, day: 220, hour: 4}), "mira-vale")

      assert look.ground == :clay

      assert %{distance_m: 60, direction: "east", flowing: false, upstream: upstream} =
               look.channel

      assert upstream in ["north", "north-east"]
      assert %{verb: :follow, directions: [:upstream, :downstream]} in look.affordances

      text = Prose.look(look)
      assert text =~ "The ground underfoot is packed clay."
      assert text =~ "The old channel runs 60 m to the east. Upstream is to the #{upstream}"
    end

    test "in 812 the river runs, warm, and steams after dark" do
      day = Perception.look(ember_view({812, day: 200, hour: 14}), "mira-vale")
      night = Perception.look(ember_view({812, day: 199, hour: 22}), "mira-vale")

      assert Prose.look(day) =~ "The river runs 60 m to the east, warm. Upstream"

      assert Prose.look(night) =~
               "The river runs 60 m to the east, warm, with steam lifting off it."
    end

    test "Mira hears the stretch beside her fall silent, not the stretches far away" do
      view = ember_view({813, day: 220, hour: 4})

      {index, _cell, _distance} =
        Terrain.nearest_channel(view.terrain, view.components.position["mira-vale"])

      beside = Terrain.reach_of(view.terrain, index)

      silent = fn reach ->
        %Event{
          type: :river_silent,
          time: view.time,
          entity: "river",
          data: %{reach: reach, position: Enum.at(Terrain.reaches(view.terrain), reach).mid}
        }
      end

      assert [%{summary: "The river falls silent.", modality: :hearing}] =
               Perception.percepts(view, "mira-vale", [silent.(beside)])

      assert Perception.percepts(view, "mira-vale", [silent.(0)]) == []
    end

    test "a spectator sees whether the river runs" do
      assert Prose.look(Perception.look(ember_view({813, day: 220, hour: 4}), nil)) =~
               "The Ember is dry."

      assert Prose.look(Perception.look(ember_view({812, day: 200, hour: 14}), nil)) =~
               "The Ember is running."
    end
  end
end
