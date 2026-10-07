defmodule Avwe.WorldSceneTest do
  use ExUnit.Case, async: true

  alias Avwe.{GroundCache, Region, Repr, WorldGround, WorldScene}
  alias Avwe.Test.Ember

  @mira "mira-vale"
  @town_hearth "town-hearth"

  # What a spectator's session works on: the region's changing state with its
  # fields, and its terrain.
  defp snapshot(region), do: region |> Region.snapshot() |> Map.put(:terrain, region.terrain)
  defp scene(region), do: region |> snapshot() |> WorldScene.build()

  defp ember(at \\ {813, day: 220, hour: 12}, holder \\ :human) do
    at |> Ember.region() |> Ember.controlled(@mira, holder)
  end

  defp light(region, id) do
    hearth = Region.get(region, id, :hearth)
    Region.put_component(region, id, :hearth, %{hearth | burning: true, lit_at: region.time})
  end

  defp ids(scene, kind), do: for(%{kind: ^kind, id: id} <- scene.things, do: id)

  describe "things" do
    test "are every body, hearth and place in the world that is somewhere, however far" do
      region = ember()
      scene = scene(region)
      components = region.components

      for {kind, component} <- [body: :body, place: :place] do
        expected =
          for {id, _} <- components[component], Map.has_key?(components.position, id), do: id

        assert ids(scene, kind) == Enum.sort(expected)
      end

      hearths = for {id, _} <- components.hearth, do: id
      assert Enum.sort(ids(scene, :hearth) ++ ids(scene, :hearth_burning)) == Enum.sort(hearths)

      # The Ember Reach: Mira, three hearths, five places, the farthest of them
      # a long walk from the town.
      assert length(scene.things) == 9
    end

    test "are sorted by kind and id" do
      things = scene(ember()).things

      assert things == Enum.sort_by(things, &{&1.kind, &1.id})
    end

    test "have the cell, the name and the glyph the world's components give" do
      region = ember()

      for thing <- scene(region).things do
        assert thing.cell == region.components.position[thing.id]
        assert thing.name == region.components.repr[thing.id].name
      end

      mira = Enum.find(scene(region).things, &(&1.id == @mira))
      assert mira.glyph == Repr.body_glyph(@mira, region.components.repr[@mira])
      assert Enum.find(scene(region).things, &(&1.kind == :place)).glyph == Repr.glyph(:place)
    end

    # The Last Coal burns without fuel, always (a standing miracle), so it is a
    # burning hearth in every scene of the Ember Reach.
    test "are told apart, for a hearth, by whether it burns" do
      cold = scene(ember())
      lit = ember() |> light(@town_hearth) |> scene()

      assert @town_hearth in ids(cold, :hearth)
      assert ids(cold, :hearth_burning) == ["the-last-coal"]
      assert ids(lit, :hearth_burning) == ["the-last-coal", @town_hearth]
      refute @town_hearth in ids(lit, :hearth)
      assert Enum.find(lit.things, &(&1.id == @town_hearth)).glyph == Repr.glyph(:hearth_burning)
    end

    test "say who holds a body, and nobody when its routine does, and only a body has a holder" do
      for holder <- [:human, :mcp, :arbor, nil] do
        mira = ember({813, day: 220, hour: 12}, holder) |> scene() |> Map.fetch!(:things)
        assert Enum.find(mira, &(&1.id == @mira)).holder == holder
      end

      assert scene(ember()).things
             |> Enum.reject(&(&1.kind == :body))
             |> Enum.all?(&(not Map.has_key?(&1, :holder)))
    end
  end

  describe "the scene" do
    test "has the world's time, and its light to a tenth: full at noon, none at night" do
      noon = scene(ember({813, day: 220, hour: 12}))
      night = scene(ember({813, day: 220, hour: 23}))

      assert noon.time == ember({813, day: 220, hour: 12}).time
      assert noon.light == 1.0
      assert night.light == 0.0

      assert scene(ember({813, day: 220, hour: 7})).light ==
               Float.round(scene(ember({813, day: 220, hour: 7})).light, 1)
    end

    test "has the three overlays: the river's reaches, the heat of the map, and the smoke" do
      scene = ember() |> light(@town_hearth) |> Region.advance(20) |> scene()

      assert length(scene.overlays.water) == 23
      assert length(scene.overlays.heat.rows) == 256
      assert [_ | _] = scene.overlays.smoke
    end

    test "has a legend of the kinds of its things, and no others" do
      scene = ember() |> light(@town_hearth) |> scene()
      kinds = scene.things |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()

      assert scene.legend |> Map.keys() |> Enum.sort() == kinds
      assert scene.legend == Repr.legend(kinds)
    end

    test "is the same scene from the same snapshot" do
      snapshot = snapshot(ember())

      assert WorldScene.build(snapshot) == WorldScene.build(snapshot)
    end

    test "is only what the world has when the world has no terrain, no river and no smoke" do
      snapshot = %{
        time: 100,
        env: %{},
        components: %{
          body: %{"a" => %{}},
          position: %{"a" => {1, 2}},
          repr: %{"a" => %{name: "A"}},
          control: %{"a" => %{holder: nil, since: nil}}
        }
      }

      scene = WorldScene.build(snapshot)

      assert [%{id: "a", kind: :body, cell: {1, 2}, name: "A", holder: nil}] = scene.things
      assert scene.light == 0.0
      assert scene.overlays == %{water: [], heat: nil, smoke: []}
    end
  end

  describe "same_view?/2" do
    test "ignores the time" do
      region = ember()
      later = %{scene(region) | time: region.time + 60}

      assert WorldScene.same_view?(scene(region), later)
    end

    test "sees the light change, which is dusk, though nothing else has" do
      scene = scene(ember())

      refute WorldScene.same_view?(scene, %{scene | light: 0.5})
    end

    test "sees a reach fall silent as the river drains" do
      region = ember({812, day: 200, hour: 15})
      drained = Region.advance(region, 40)

      refute WorldScene.same_view?(scene(region), scene(drained))
    end

    test "sees smoke drift, and a body move" do
      lit = ember() |> light(@town_hearth) |> Region.advance(10)

      refute WorldScene.same_view?(scene(lit), scene(Region.advance(lit, 1)))

      moved = Region.put_component(ember(), @mira, :position, {10, 10})
      refute WorldScene.same_view?(scene(ember()), scene(moved))
    end
  end

  describe "as plain data" do
    test "is JSON, with the same cells, and a cell as [x, y]" do
      map = ember() |> light(@town_hearth) |> Region.advance(20) |> scene() |> WorldScene.to_map()

      assert map |> Jason.encode!() |> Jason.decode!() == map
      assert Map.keys(map) |> Enum.sort() == ["legend", "light", "overlays", "things", "time"]
      assert [%{"cell" => [_x, _y]} | _] = map["things"]
    end

    test "gives a body its holder and no other thing" do
      things = ember() |> scene() |> WorldScene.to_map() |> Map.fetch!("things")

      assert Enum.find(things, &(&1["id"] == @mira))["holder"] == "human"

      assert things
             |> Enum.reject(&(&1["kind"] == "body"))
             |> Enum.all?(&(not Map.has_key?(&1, "holder")))
    end

    test "has each overlay's layers beside its data, so a client holds no table" do
      overlays = ember() |> scene() |> WorldScene.to_map() |> Map.fetch!("overlays")

      assert overlays["water"]["colors"] == %{
               "flowing" => Repr.glyph(:water).color,
               "silent" => Repr.glyph(:channel_bed).color,
               "steam" => "#e8eef2"
             }

      assert [%{"at" => _, "color" => "#" <> _} | _] = overlays["heat"]["ramp"]
      assert overlays["heat"]["unit"] == "°C"
      assert overlays["smoke"]["color"] == Repr.overlay(:smoke).color
      assert length(overlays["water"]["reaches"]) == 23
      assert overlays["heat"]["rows"] |> length() == 256
    end

    test "has no heat to give a world that has none" do
      snapshot = %{time: 1, env: %{}, components: %{}}

      assert snapshot |> WorldScene.build() |> WorldScene.to_map() |> get_in(["overlays", "heat"]) ==
               nil
    end
  end

  # The browser's tests (assets/test) read what the server really builds, so that
  # what they check is the format it sends. These keep them honest: if a scene
  # changes, this fails, and the files are written again with
  # `AVWE_UPDATE_FIXTURES=1 mix test test/avwe/world_scene_test.exs`.
  describe "the scenes the browser's tests read" do
    @fixtures Path.expand("../../assets/test/fixtures", __DIR__)

    defp fixture!(name, map) do
      path = Path.join(@fixtures, "#{name}.json")

      if System.get_env("AVWE_UPDATE_FIXTURES") == "1" do
        File.write!(path, Jason.encode!(map, pretty: true) <> "\n")
      end

      assert path |> File.read!() |> Jason.decode!() == map
    end

    # The hour after the source fails: the river runs, and the town hearth is
    # lit and smoking.
    test "world_flowing: the Ember Reach with the river running, the town hearth lit" do
      region = {812, day: 200, hour: 14} |> ember() |> light(@town_hearth) |> Region.advance(20)

      fixture!("world_flowing", region |> scene() |> WorldScene.to_map())
    end

    # An hour and a half after, the silence has come down the river a way.
    test "world_drying: the same, an hour and a half after the source fails" do
      region =
        {812, day: 200, hour: 14}
        |> ember()
        |> light(@town_hearth)
        |> Region.advance(150)

      map = region |> scene() |> WorldScene.to_map()
      silent = Enum.count(map["overlays"]["water"]["reaches"], & &1["silent"])
      assert silent in 5..20

      fixture!("world_drying", map)
    end

    test "world_ground: the ground of the Ember Reach" do
      terrain = Ember.region().terrain

      fixture!("world_ground", terrain |> GroundCache.world() |> WorldGround.to_map())
    end
  end
end
