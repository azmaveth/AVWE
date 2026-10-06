defmodule Avwe.PerceptionTest do
  use ExUnit.Case, async: true

  alias Avwe.{Calendar, Event, Perception, Prose, Quire, Region, Terrain}
  alias Avwe.Systems.{Daylight, Fire, Smoke}
  alias Avwe.Test.{Ember, Fixtures}

  @mira "mira-vale"
  @lodge "lodge-hearth"
  @town "town-hearth"
  @coal "the-last-coal"
  @dawn {813, day: 220, hour: 4}

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
                 issuer: :controller,
                 outcome: :success,
                 summary: "You arrive at Mill Pond."
               }
             ] =
               Perception.percepts(view, "wren", [result])

      assert Perception.percepts(view, "tamsin", [result]) == []
      assert Perception.percepts(view, nil, [result]) == []
    end

    test "the routine's actions say so, and its waits say nothing", %{world: world} do
      view = view(world, 12)

      started = %Event{
        type: :action_started,
        time: view.time,
        entity: "wren",
        data: %{ref: "auto-wren-7", verb: :go, target: "mill-pond", params: %{}}
      }

      assert [%{kind: :progress, intent: "auto-wren-7", issuer: :autopilot}] =
               Perception.percepts(view, "wren", [started])

      wait = %{
        started
        | data: %{ref: "auto-wren-7", verb: :wait, target: nil, params: %{for: 600}}
      }

      ended = %{
        wait
        | type: :action_result,
          data: Map.merge(wait.data, %{outcome: :success, reason: :done})
      }

      assert Perception.percepts(view, "wren", [wait, ended]) == []

      # Except a wait the controller stopped: they asked, so it answers.
      stopped = %{
        ended
        | data: %{ended.data | outcome: :interrupted, reason: :stopped}
      }

      assert [
               %{
                 kind: :result,
                 intent: "auto-wren-7",
                 issuer: :autopilot,
                 reason: :stopped,
                 summary: "You stop waiting."
               }
             ] = Perception.percepts(view, "wren", [stopped])

      own = %{wait | data: %{wait.data | ref: "i-7"}}

      assert [%{kind: :progress, intent: "i-7", issuer: :controller}] =
               Perception.percepts(view, "wren", [own])
    end

    test "only the body senses the hand-over between its controller and its routine", %{
      world: world
    } do
      view = view(world, 12)

      released = %Event{
        type: :control_released,
        time: view.time,
        entity: "wren",
        data: %{controller: :human}
      }

      taken = %{released | type: :control_taken}

      assert [
               %{
                 kind: :sensed,
                 type: :control_released,
                 body: "wren",
                 salience: 0.3,
                 summary: "You let your routine carry you."
               },
               %{kind: :sensed, type: :control_taken, summary: "You take yourself in hand."}
             ] = Perception.percepts(view, "wren", [released, taken])

      assert Perception.percepts(view, "tamsin", [released, taken]) == []
      assert Perception.percepts(view, nil, [released, taken]) == []
    end
  end

  describe "the river" do
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
      day = Perception.look(ember_snapshot({812, day: 200, hour: 14}), "mira-vale")
      night = Perception.look(ember_snapshot({812, day: 199, hour: 22}), "mira-vale")

      refute day.channel.steaming
      assert Prose.look(day) =~ "The river runs 60 m to the east, warm. Upstream"

      assert night.channel.steaming

      assert Prose.look(night) =~
               "The river runs 60 m to the east, warm, with steam lifting off it."
    end

    test "the river steams when its reach's banks do, by day as much as by night" do
      night = Perception.look(ember_snapshot({812, day: 199, hour: 22}), "mira-vale")
      assert night.channel.steaming

      still = Prose.look(put_in(night.channel.steaming, false))
      assert still =~ "The river runs 60 m to the east, warm. Upstream"
      refute still =~ "steam"

      # Full daylight: no light clause stands between a steaming reach and
      # the prose, so the river never steams while the silt is said not to.
      day = Perception.look(ember_snapshot({812, day: 200, hour: 14}), "mira-vale")
      assert day.light > 0.3
      refute day.channel.steaming

      # And when the banks do steam before sunset, the look says so in daylight.
      evening =
        Perception.look(ember_snapshot({812, day: 199, hour: 17, minute: 30}), "mira-vale")

      assert evening.light > 0.3
      assert evening.channel.steaming
      assert Prose.look(evening) =~ "warm, with steam lifting off it."

      steams = Prose.look(put_in(day.channel.steaming, true))
      assert steams =~ "The river runs 60 m to the east, warm, with steam lifting off it."

      # A view without fields has no flag, and the river does not steam.
      refute Perception.look(ember_view({812, day: 199, hour: 22}), "mira-vale").channel.steaming
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

  describe "heat and fire" do
    # What a session's `look` sees: the snapshot, with its fields, and the terrain.
    defp ember_snapshot(at) do
      region = Ember.region(at)
      region |> Region.snapshot() |> Map.put(:terrain, region.terrain)
    end

    defp at(view, body, cell), do: put_in(view, [:components, :position, body], cell)

    defp lit(view, id),
      do: update_in(view, [:components, :hearth, id], &%{&1 | burning: true, lit_at: view.time})

    defp with_smoke(view, {x, y}, grams) do
      puff = %{x: x + 0.5, y: y + 0.5, g: grams, born: view.time * 1.0}
      put_in(view, [:fields, :smoke], %{puffs: [puff], last_step: Smoke.new().last_step})
    end

    defp verbs(look), do: Enum.map(look.affordances, & &1.verb)

    test "at the lodge before dawn, Mira feels the Last Coal and finds the hearth laid" do
      look = Perception.look(at(ember_snapshot(@dawn), @mira, Ember.places().lodge), @mira)

      assert %{fire: %{ref: @coal, name: "The Last Coal", level: :warm}, air_c: air_c} =
               look.warmth

      assert air_c < 15
      assert %{id: @lodge, burning: false, fuel_kg: 12.0, distance_m: 0} = look.hearth
      assert [%{id: @lodge}, %{id: @coal, burning: true, fuel_kg: +0.0}] = look.hearths
      assert [%{ref: @coal, level: :warm}] = look.warmth.sources
      assert %{verb: :kindle, targets: [@lodge]} in look.affordances
      refute :douse in verbs(look)

      text = Prose.look(look)
      assert text =~ "The air is cool."
      assert text =~ "The lodge hearth is cold, with wood laid.\nThe Last Coal is burning here."
      assert text =~ "Warmth reaches you from The Last Coal."
    end

    test "with the lodge hearth lit, both fires are here and both warm her; she can douse one" do
      view = @dawn |> ember_snapshot() |> lit(@lodge) |> at(@mira, Ember.places().lodge)
      look = Perception.look(view, @mira)

      assert %{fire: %{ref: @lodge, level: :hot}} = look.warmth
      assert [%{ref: @lodge, level: :hot}, %{ref: @coal, level: :warm}] = look.warmth.sources
      assert [%{id: @lodge, burning: true}, %{id: @coal, burning: true}] = look.hearths
      assert %{verb: :douse, targets: [@lodge]} in look.affordances
      refute :kindle in verbs(look)

      text = Prose.look(look)
      assert text =~ "The lodge hearth is burning here.\nThe Last Coal is burning here."
      assert text =~ "The fire's heat is on your face. Warmth reaches you from The Last Coal."
    end

    test "a faint warmth reaches the next cell" do
      {x, y} = Ember.places().lodge
      view = @dawn |> ember_snapshot() |> lit(@lodge) |> at(@mira, {x + 1, y})

      assert Prose.look(Perception.look(view, @mira)) =~
               "You feel a faint warmth from the lodge hearth."
    end

    test "at night a burning hearth 150 m off shows as a glow; one 550 m off does not" do
      {x, y} = Ember.places().lodge
      view = @dawn |> ember_snapshot() |> lit(@lodge) |> lit(@town) |> at(@mira, {x, y - 15})
      look = Perception.look(view, @mira)

      assert [
               %{ref: @lodge, name: "the lodge hearth", distance_m: 150, direction: "south"},
               %{ref: @coal, sign: :glow}
             ] = Enum.sort_by(look.fires, & &1.ref)

      assert hd(look.fires).sign == :glow
      refute Enum.any?(look.fires, &(&1.ref == @town))
      assert Prose.look(look) =~ "A glow shows at the lodge hearth, 150 m to the south."
    end

    test "by day a fire shows by its smoke, and the Last Coal, which gives none, not at all" do
      {x, y} = Ember.places().lodge

      look =
        {813, day: 220, hour: 12}
        |> ember_snapshot()
        |> lit(@lodge)
        |> at(@mira, {x, y - 15})
        |> Perception.look(@mira)

      assert [%{ref: @lodge, sign: :smoke, distance_m: 150}] = look.fires
      assert Prose.look(look) =~ "Smoke rises from the lodge hearth, 150 m to the south."
    end

    test "a burning hearth within 20 m is what is here, not a fire in sight" do
      {x, y} = lodge = Ember.places().lodge
      view = @dawn |> ember_snapshot() |> lit(@lodge)

      # On the lodge hearth and the Last Coal, and two cells off (the hearth
      # is still within reach), neither is in `fires`; three cells off both are.
      for cell <- [lodge, {x + 2, y}] do
        look = Perception.look(at(view, @mira, cell), @mira)
        assert look.fires == []
        assert %{id: @lodge, burning: true} = look.hearth
        refute Prose.look(look) =~ "A glow shows"
      end

      look = Perception.look(at(view, @mira, {x + 3, y}), @mira)
      assert look.hearth == nil
      assert look.hearths == []
      refute Prose.look(look) =~ "is burning here."

      assert [%{ref: @lodge, sign: :glow, distance_m: 30}, %{ref: @coal, sign: :glow}] =
               look.fires
    end

    test "at dusk a fire shows by its smoke until the light falls below a tenth" do
      {x, y} = Ember.places().lodge

      # 18:00 is dusk: the light is 0.24. By 18:40 it is 0.08.
      dusk =
        {813, day: 220, hour: 18}
        |> ember_snapshot()
        |> lit(@lodge)
        |> at(@mira, {x, y - 15})
        |> Perception.look(@mira)

      assert dusk.light > 0.1 and dusk.light < 0.3
      assert [%{ref: @lodge, sign: :smoke}] = dusk.fires
      assert Prose.look(dusk) =~ "Smoke rises from the lodge hearth, 150 m to the south."

      dark =
        {813, day: 220, hour: 18, minute: 40}
        |> ember_snapshot()
        |> lit(@lodge)
        |> at(@mira, {x, y - 15})
        |> Perception.look(@mira)

      assert dark.light > 0 and dark.light < 0.1
      assert [%{ref: @lodge, sign: :glow}, %{ref: @coal, sign: :glow}] = dark.fires
      assert Prose.look(dark) =~ "A glow shows at the lodge hearth, 150 m to the south."
    end

    test "kindling is offered only within 20 m of a hearth" do
      {x, y} = Ember.places().town
      view = ember_snapshot(@dawn)

      assert %{verb: :kindle, targets: [@town]} in Perception.look(view, @mira).affordances

      assert %{verb: :kindle, targets: [@town]} in Perception.look(
               at(view, @mira, {x + 2, y}),
               @mira
             ).affordances

      refute :kindle in verbs(Perception.look(at(view, @mira, {x + 3, y}), @mira))
    end

    test "without fields there is no warmth and no smoke" do
      look = Perception.look(ember_view(@dawn), @mira)

      assert look.warmth == nil
      assert look.smoke == nil
      assert %{id: @town, burning: false} = look.hearth
      assert [%{id: @town}] = look.hearths
      assert Prose.look(look) =~ "The kiln-house hearth is cold, with wood laid."
    end

    test "smoke on the spot is thick; a wisp is faint, and comes with the wind" do
      town = Ember.places().town
      view = ember_snapshot(@dawn)

      thick = Perception.look(with_smoke(view, town, 0.1875), @mira)
      assert thick.smoke == %{level: :thick, from: "south-west"}
      assert Prose.look(thick) =~ "The smoke is thick here."

      faint = Perception.look(with_smoke(view, town, 0.003), @mira)
      assert faint.smoke == %{level: :faint, from: "south-west"}
      assert Prose.look(faint) =~ "Woodsmoke, faint, from the south-west."
    end

    test "at a hearth that smoked this step the smoke is at least on the wind" do
      {x, y} = town = Ember.places().town

      smoked = %{Fire.zero_step() | burn_s: 60.0, burned_kg: 0.01875, smoke_g: 0.1875}

      view = @dawn |> ember_snapshot() |> lit(@town)
      view = update_in(view, [:components, :hearth, @town], &%{&1 | last_step: smoked})

      # No puff in the air at all: the rule alone says the smoke is here.
      at_hearth = Perception.look(with_smoke(view, {x, y - 20}, 0.0), @mira)
      assert at_hearth.smoke == %{level: :clear, from: "south-west"}
      assert Prose.look(at_hearth) =~ "Woodsmoke on the wind from the south-west."

      # A thick puff on the spot is still thick; two cells off, the rule is silent.
      thick = Perception.look(with_smoke(view, town, 0.1875), @mira)
      assert thick.smoke.level == :thick

      assert Perception.look(at(with_smoke(view, {x, y - 20}, 0.0), @mira, {x + 2, y}), @mira).smoke ==
               nil
    end

    test "smoke comes with the region's wind, not the default one" do
      town = Ember.places().town
      view = put_in(ember_snapshot(@dawn), [:env, :wind], %{from: "north", m_s: 2.0})

      clear = Perception.look(with_smoke(view, town, 0.05), @mira)
      assert clear.smoke == %{level: :clear, from: "north"}
      assert Prose.look(clear) =~ "Woodsmoke on the wind from the north."

      faint = Perception.look(with_smoke(view, town, 0.003), @mira)
      assert faint.smoke == %{level: :faint, from: "north"}
      assert Prose.look(faint) =~ "Woodsmoke, faint, from the north."
    end

    test "at two in the afternoon the air is warm and the clay underfoot has warmed" do
      look = Perception.look(ember_snapshot({813, day: 220, hour: 14}), @mira)

      assert %{air_c: air_c, ground: :warm, steam?: false} = look.warmth
      assert air_c >= 22
      assert Prose.look(look) =~ "The air is warm. The ground is warm underfoot."
    end

    test "at seven the ground lags the warming air and is cold" do
      look = Perception.look(ember_snapshot({813, day: 220, hour: 7}), @mira)

      assert %{air_c: air_c, ground: :cold} = look.warmth
      assert air_c >= 15 and air_c < 22
      assert Prose.look(look) =~ "\nThe ground is cold.\n"
    end

    test "in the warm river at night the water steams; on the reeds, the reeds" do
      {x, y} = Ember.places().town
      view = ember_snapshot({812, day: 199, hour: 22})

      water = Perception.look(at(view, @mira, {x + 7, y}), @mira)
      assert water.ground == :channel_bed
      assert %{ground: :hot, steam?: true} = water.warmth
      text = Prose.look(water)
      assert text =~ "You are standing in the river."
      assert text =~ "The air is cool. The ground is hot underfoot. Steam lifts off the water."

      reeds = Perception.look(at(view, @mira, {x + 8, y}), @mira)
      assert reeds.ground == :reeds
      assert %{ground: :hot, steam?: true} = reeds.warmth
      text = Prose.look(reeds)
      assert text =~ "Reeds crowd the river's edge here."
      assert text =~ "The air is cool. The ground is hot underfoot. Steam lifts off the reeds."

      # The silt cools with distance from the channel: warm, not hot, 110 m out.
      silt = Perception.look(at(view, @mira, {x + 11, y}), @mira)
      assert silt.ground == :silt
      assert %{ground: :warm, steam?: true} = silt.warmth

      assert Prose.look(silt) =~
               "The air is cool. The ground is warm underfoot. Steam lifts off the silt."
    end

    test "on the silt beside the running river at night, the banks steam" do
      {x, y} = Ember.places().town
      view = at(ember_snapshot({812, day: 199, hour: 22}), @mira, {x + 9, y})
      look = Perception.look(view, @mira)

      assert look.ground == :silt
      assert %{steam?: true, ground: band} = look.warmth
      assert band in [:warm, :hot]
      assert look.channel.air_c == view.env.air_c

      text = Prose.look(look)
      assert text =~ "underfoot. Steam lifts off the silt."
      assert text =~ "with steam lifting off it."
    end

    test "a spectator sees every hearth and which banks steam" do
      look = Perception.look(ember_snapshot({812, day: 199, hour: 22}), nil)

      assert [%{id: @lodge, burning: false}, %{id: @coal, burning: true}, %{id: @town}] =
               look.fires

      assert %{air_c: air_c, steaming_reaches: [0 | _rest]} = look.heat
      assert is_float(air_c)
      assert Prose.look(look) =~ "The Last Coal is burning."
    end
  end

  describe "fire, steam and smoke percepts" do
    defp fire_event(type, view, data) do
      %Event{type: type, time: view.time, entity: @lodge, data: data}
    end

    test "a fire is seen 200 m off at night, not 210 m" do
      {x, y} = lodge = Ember.places().lodge
      view = ember_snapshot(@dawn)
      lit = fire_event(:fire_lit, view, %{position: lodge, by: @mira, ref: "i-3"})

      assert [
               %{
                 summary: "You light the lodge hearth.",
                 modality: :sight,
                 salience: 0.7,
                 issuer: :controller
               }
             ] = Perception.percepts(at(view, @mira, {x, y + 20}), @mira, [lit])

      assert Perception.percepts(at(view, @mira, {x, y + 21}), @mira, [lit]) == []

      assert [%{summary: "Mira Vale lights the lodge hearth.", issuer: nil}] =
               Perception.percepts(view, nil, [lit])
    end

    test "the body's own fire says who asked for it; another's does not" do
      lodge = Ember.places().lodge
      view = at(ember_snapshot(@dawn), @mira, lodge)

      routine =
        fire_event(:fire_lit, view, %{position: lodge, by: @mira, ref: "auto-mira-vale-9"})

      doused =
        fire_event(:fire_out, view, %{position: lodge, reason: :doused, by: @mira, ref: "i-4"})

      other = fire_event(:fire_lit, view, %{position: lodge, by: "tam", ref: "i-1"})

      assert [
               %{summary: "You light the lodge hearth.", issuer: :autopilot},
               %{summary: "You douse the lodge hearth.", issuer: :controller},
               %{summary: "tam lights the lodge hearth.", issuer: nil}
             ] = Perception.percepts(view, @mira, [routine, doused, other])
    end

    test "burning low and going out are seen, and say who doused it" do
      {x, y} = lodge = Ember.places().lodge
      view = at(ember_snapshot(@dawn), @mira, lodge)
      low = fire_event(:fire_low, view, %{position: lodge})
      fuel = fire_event(:fire_out, view, %{position: lodge, reason: :fuel, by: nil})
      doused = fire_event(:fire_out, view, %{position: lodge, reason: :doused, by: @mira})

      # At the hearth it is "the fire"; further off, or watching, it is named.
      assert [
               %{summary: "The fire burns low.", salience: 0.5},
               %{summary: "The fire goes out.", salience: 0.6},
               %{summary: "You douse the lodge hearth."}
             ] = Perception.percepts(view, @mira, [low, fuel, doused])

      assert [
               %{summary: "The fire burns low."},
               %{summary: "The fire goes out."}
             ] = Perception.percepts(at(view, @mira, {x + 2, y}), @mira, [low, fuel])

      assert [
               %{summary: "The lodge hearth burns low."},
               %{summary: "The fire at the lodge hearth goes out."}
             ] = Perception.percepts(at(view, @mira, {x + 3, y}), @mira, [low, fuel])

      assert [
               %{summary: "The lodge hearth burns low."},
               %{summary: "The fire at the lodge hearth goes out."},
               %{summary: "Mira Vale douses the lodge hearth."}
             ] = Perception.percepts(view, nil, [low, fuel, doused])
    end

    test "steam is seen on the stretch beside the body, and once per place by a spectator" do
      view = ember_view({812, day: 199, hour: 22})

      {index, _cell, _distance} =
        Terrain.nearest_channel(view.terrain, view.components.position[@mira])

      beside = Terrain.reach_of(view.terrain, index)

      steam = fn type, reach ->
        %Event{
          type: type,
          time: view.time,
          entity: "river",
          data: %{reach: reach, position: Enum.at(Terrain.reaches(view.terrain), reach).mid}
        }
      end

      assert [
               %{summary: "Steam begins to rise from the banks.", modality: :sight, salience: 0.6}
             ] = Perception.percepts(view, @mira, [steam.(:steam_rising, beside)])

      assert [%{summary: "The steam over the banks thins and is gone."}] =
               Perception.percepts(view, @mira, [steam.(:steam_fading, beside)])

      assert Perception.percepts(view, @mira, [steam.(:steam_rising, 0)]) == []

      assert [%{summary: "Steam begins to rise from the banks near The Source."}] =
               Perception.percepts(view, nil, [steam.(:steam_rising, 0)])
    end

    test "only the body's own nose smells smoke" do
      view = ember_view(@dawn)

      smelled = %Event{
        type: :smoke_smelled,
        time: view.time,
        entity: @mira,
        data: %{level: :faint, from: "north"}
      }

      faded = %Event{type: :smoke_faded, time: view.time, entity: @mira, data: %{}}

      assert [
               %{
                 summary: "You smell woodsmoke, faint, from the north.",
                 modality: :smell,
                 salience: 0.5
               },
               %{summary: "The smell of smoke fades.", modality: :smell}
             ] = Perception.percepts(view, @mira, [smelled, faded])

      assert [%{salience: 0.7}] =
               Perception.percepts(view, @mira, [put_in(smelled.data.level, :clear)])

      assert Perception.percepts(view, nil, [smelled, faded]) == []
      assert Perception.percepts(view, "someone-else", [smelled]) == []
    end
  end
end
