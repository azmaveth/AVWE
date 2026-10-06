defmodule Avwe.SceneTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.{Calendar, GroundCache, Perception, Quire, Region, Repr, Scene, Space, Terrain}
  alias Avwe.Systems.Daylight
  alias Avwe.Test.{Ember, Fixtures}

  @mira "mira-vale"
  @dry_bend {163, 78}
  @lodge_cell {94, 105}

  # The view a session works on: the region's view, its terrain, and the
  # ground map a session adds when it wants scenes.
  defp view(region) do
    region
    |> Region.view()
    |> Map.put(:terrain, region.terrain)
    |> Map.put(:ground, GroundCache.fetch(region.terrain))
  end

  defp ember(at, cell \\ nil) do
    region = Ember.region(at) |> Ember.controlled()
    if cell, do: Region.put_component(region, @mira, :position, cell), else: region
  end

  defp at_noon(cell \\ nil), do: ember({813, day: 220, hour: 12}, cell)
  defp at_night(cell \\ nil), do: ember({813, day: 220, hour: 22}, cell)

  defp light_up(region, hearth) do
    burning = %{Region.get(region, hearth, :hearth) | burning: true}
    Region.put_component(region, hearth, :hearth, burning)
  end

  defp window_cells(scene) do
    {ox, oy} = scene.origin
    for dy <- 0..(scene.size - 1), dx <- 0..(scene.size - 1), do: {ox + dx, oy + dy}
  end

  defp kinds_in(scene) do
    scene
    |> window_cells()
    |> Enum.map(&Scene.kind_at(scene, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  describe "sight" do
    test "is 50 cells at noon and 5 at night, and the window holds the circle" do
      noon = Scene.build(view(at_noon()), @mira)
      assert noon.radius == 50.0
      assert noon.size == 101
      assert noon.center == {121, 138}
      assert noon.origin == {71, 88}
      assert noon.light == 1.0

      night = Scene.build(view(at_night()), @mira)
      assert night.radius == 5.0
      assert night.size == 11
      assert night.light == 0.0
    end

    test "is quantized to half a cell, and light to a tenth, so a scene does not change every minute at dusk" do
      for hour <- 5..8, minute <- [0, 20, 40] do
        region = ember({813, day: 220, hour: hour, minute: minute})
        scene = Scene.build(view(region), @mira)

        assert scene.radius * 2 == Float.round(scene.radius * 2)
        assert scene.radius >= Perception.sight_cells(region.env.light)
        assert scene.radius - Perception.sight_cells(region.env.light) < 0.5
        assert scene.light == Float.round(scene.light, 1)
      end
    end

    test "shows ground only inside the circle, as a round disc, and nothing off the map" do
      for region <- [at_noon(), at_night(), at_noon({3, 4})] do
        scene = Scene.build(view(region), @mira)
        terrain = region.terrain

        for {x, y} = cell <- window_cells(scene) do
          inside? = Space.distance(scene.center, cell) <= scene.radius
          on_map? = x >= 0 and x < terrain.width and y >= 0 and y < terrain.height

          if inside? and on_map?,
            do: assert(Scene.kind_at(scene, cell) != nil, "#{inspect(cell)} should be seen"),
            else: assert(Scene.kind_at(scene, cell) == nil, "#{inspect(cell)} should be blank")
        end
      end
    end

    test "is the terrain's own ground, cell by cell, in a land where the river is dry" do
      region = at_noon(@dry_bend)
      scene = Scene.build(view(region), @mira)

      for cell <- window_cells(scene), kind = Scene.kind_at(scene, cell), kind != nil do
        assert kind == Terrain.ground(region.terrain, cell), inspect(cell)
      end

      assert :channel_bed in kinds_in(scene)
      refute :water in kinds_in(scene)
    end
  end

  describe "the river" do
    test "runs where it runs: the same bed is water in 812 and dry in 813" do
      wet = Scene.build(view(ember({812, day: 200, hour: 12}, @dry_bend)), @mira)
      dry = Scene.build(view(ember({813, day: 220, hour: 12}, @dry_bend)), @mira)

      assert :water in kinds_in(wet)
      refute :channel_bed in kinds_in(wet)
      refute :water in kinds_in(dry)
      assert :channel_bed in kinds_in(dry)

      assert Map.has_key?(wet.legend, :water)
      refute Map.has_key?(dry.legend, :water)
    end

    test "falls silent downstream after the source fails, and the bed is dry again" do
      region = ember({812, day: 200, hour: 13}, @dry_bend)
      assert :water in kinds_in(Scene.build(view(region), @mira))

      dried = Region.advance(region, 7 * 60)
      assert region.step < dried.step
      scene = Scene.build(view(dried), @mira)
      refute :water in kinds_in(scene)
      assert :channel_bed in kinds_in(scene)
    end
  end

  describe "things" do
    test "are the places a body knows that are in sight, and a hearth within reach, at noon in the town" do
      scene = Scene.build(view(at_noon()), @mira)

      assert [
               %{kind: :hearth, name: "the kiln-house hearth", cell: {121, 138}},
               %{kind: :place, name: "Ashwarden Lodge", cell: @lodge_cell},
               %{kind: :place, name: "Ember Reach", cell: {121, 138}},
               %{kind: :place, name: "Willow Docks", cell: {138, 162}}
             ] = scene.things

      for thing <- scene.things do
        assert thing.glyph == Repr.glyph(thing.kind), inspect(thing)
        assert Map.has_key?(scene.legend, thing.kind)
      end
    end

    test "leave out a known place that is beyond sight, which the look still lists" do
      region = at_noon({121, 20})
      scene = Scene.build(view(region), @mira)
      look = Perception.look(Region.view(region) |> Map.put(:terrain, region.terrain), @mira)

      names = Enum.map(scene.things, & &1.name)
      assert "Ashwarden Lodge" in Enum.map(look.places, & &1.name)
      refute "Ashwarden Lodge" in names
    end

    test "show a fire by its glow from beyond sight at night, and the window grows to hold it" do
      region = at_night({94, 90}) |> light_up("lodge-hearth")
      scene = Scene.build(view(region), @mira)

      assert %{kind: :glow, cell: @lodge_cell} = Enum.find(scene.things, &(&1.kind == :glow))
      assert scene.radius == 5.0
      assert scene.size >= 2 * 15 + 1
      assert Scene.kind_at(scene, @lodge_cell) == nil
      assert Map.has_key?(scene.legend, :glow)
    end

    test "tell a burning hearth from a cold one" do
      cold = Scene.build(view(at_noon()), @mira)

      assert [%{kind: :hearth}] =
               Enum.filter(cold.things, &(&1.kind in [:hearth, :hearth_burning]))

      lit = Scene.build(view(light_up(at_noon(), "town-hearth")), @mira)

      assert [%{kind: :hearth_burning}] =
               Enum.filter(lit.things, &(&1.kind in [:hearth, :hearth_burning]))
    end

    test "are bodies in sight, each with its own glyph, never the viewer" do
      region =
        at_noon()
        |> add_body("wren", {130, 140}, %{char: "W", color: "#112233"})
        |> add_body("pell", {121, 160}, nil)
        |> add_body("far", {121, 230}, nil)

      scene = Scene.build(view(region), @mira)
      bodies = Enum.filter(scene.things, &(&1.kind == :body))

      assert Enum.map(bodies, & &1.id) == ["pell", "wren"]

      assert %{glyph: %{char: "W", color: "#112233"}, cell: {130, 140}} =
               Enum.find(bodies, &(&1.id == "wren"))

      assert %{glyph: %{char: "@"}} = Enum.find(bodies, &(&1.id == "pell"))
      assert scene.you.id == @mira
    end
  end

  describe "the viewer" do
    test "is drawn by its own glyph when its world gave it one, else by its id's color" do
      scene = Scene.build(view(at_noon()), @mira)
      assert scene.you == %{id: @mira, name: "Mira Vale", glyph: Repr.body_glyph(@mira, nil)}

      region = at_noon()
      repr = Map.put(Region.get(region, @mira, :repr), :glyph, %{char: "M", color: "#e8c07a"})
      region = Region.put_component(region, @mira, :repr, repr)
      assert Scene.build(view(region), @mira).you.glyph == %{char: "M", color: "#e8c07a"}
    end

    test "carries who holds its body" do
      assert Scene.build(view(at_noon()), @mira).holder == :human
      assert Scene.build(view(Ember.region({813, day: 220, hour: 12})), @mira).holder == nil
    end

    test "has no scene as a spectator, or when the body is nowhere" do
      assert Scene.build(view(at_noon()), nil) == nil

      region = at_noon()

      nowhere = %{
        region
        | components: update_in(region.components, [:position], &Map.delete(&1, @mira))
      }

      assert Scene.build(view(nowhere), @mira) == nil
    end
  end

  describe "a world with no terrain" do
    setup do
      {:ok, world} = Quire.load(Fixtures.lantern_hollow())

      view =
        world
        |> Quire.Seed.region(
          id: {0, 0},
          seed: 1,
          time: Calendar.at(1, hour: 12),
          systems: [Daylight]
        )
        |> Region.prepare()
        |> Region.view()

      %{view: view}
    end

    test "has things and no ground", %{view: view} do
      scene = Scene.build(view, "wren")

      assert scene.rows == nil
      assert Scene.kind_at(scene, scene.center) == nil
      assert scene.legend |> Map.keys() |> Enum.sort() == [:body, :place]

      # Far Tower, 1530 m off, is known and out of sight; Odo is there.
      assert Enum.map(scene.things, & &1.name) |> Enum.sort() ==
               ["Hollow Green", "Mill Pond", "Pell", "Tamsin"]
    end

    test "still sizes its window to hold what it shows", %{view: view} do
      scene = Scene.build(view, "wren")
      {cx, _cy} = scene.center
      assert scene.size >= 2 * 50 + 1
      assert elem(scene.origin, 0) == cx - div(scene.size - 1, 2)
    end
  end

  describe "rows" do
    test "decode to exactly one cell for each of the window's, with the letters the moduledoc names" do
      for region <- [at_noon(), at_night(@dry_bend), ember({812, day: 200, hour: 12}, @dry_bend)] do
        scene = Scene.build(view(region), @mira)
        assert length(scene.rows) == scene.size

        for row <- scene.rows do
          assert row =~ ~r/\A([gsctrbw.]\d+)+\z/, row

          cells =
            ~r/([a-z.])(\d+)/
            |> Regex.scan(row)
            |> Enum.map(fn [_, _, n] -> String.to_integer(n) end)

          assert Enum.sum(cells) == scene.size
        end
      end
    end

    test "stay small: a noon window is a few kilobytes, not ten" do
      scene = Scene.build(view(at_noon()), @mira)
      assert scene.rows |> Enum.join() |> byte_size() < 4_000
    end
  end

  describe "same_view?/2" do
    test "ignores the time and nothing else" do
      region = at_noon()
      a = Scene.build(view(region), @mira)
      later = %{region | time: region.time + 60}
      b = Scene.build(view(later), @mira)

      assert a.time != b.time
      assert Scene.same_view?(a, b)

      moved = Scene.build(view(Region.put_component(region, @mira, :position, {122, 138})), @mira)
      refute Scene.same_view?(a, moved)

      lit = Scene.build(view(light_up(region, "town-hearth")), @mira)
      refute Scene.same_view?(a, lit)
    end
  end

  describe "to_map/1" do
    test "is plain data that goes to JSON and back unchanged" do
      scene = Scene.build(view(light_up(at_night(), "town-hearth")), @mira)
      map = Scene.to_map(scene)

      assert map |> Jason.encode!() |> Jason.decode!() == map
    end

    test "says what the scene says, with cells as pairs and kinds as strings" do
      scene = Scene.build(view(light_up(at_night(), "town-hearth")), @mira)
      map = Scene.to_map(scene)
      {cx, cy} = scene.center
      {ox, oy} = scene.origin

      assert %{"center" => [^cx, ^cy], "origin" => [^ox, ^oy], "size" => 11, "radius" => 5.0} =
               map

      assert map["light"] == 0.0
      assert map["time"] == scene.time
      assert map["rows"] == scene.rows
      assert map["holder"] == "human"

      assert %{
               "id" => "mira-vale",
               "name" => "Mira Vale",
               "glyph" => %{"char" => "@", "color" => _}
             } =
               map["you"]

      assert %{"id" => "town-hearth", "kind" => "hearth_burning", "cell" => [^cx, ^cy]} =
               Enum.find(map["things"], &(&1["id"] == "town-hearth"))

      assert Enum.map(map["things"], & &1["kind"]) |> Enum.uniq() |> Enum.all?(&is_binary/1)
      assert %{"name" => "clay", "glyph" => %{"char" => ":"}} = map["legend"]["clay"]
      assert Map.keys(map["legend"]) |> Enum.all?(&is_binary/1)
    end

    test "keeps what is missing missing: no rows without terrain, no holder for a routine" do
      {:ok, world} = Quire.load(Fixtures.lantern_hollow())

      view =
        world
        |> Quire.Seed.region(
          id: {0, 0},
          seed: 1,
          time: Calendar.at(1, hour: 12),
          systems: [Daylight]
        )
        |> Region.prepare()
        |> Region.view()

      map = view |> Scene.build("wren") |> Scene.to_map()

      assert map["rows"] == nil
      assert map["holder"] == nil
      assert map |> Jason.encode!() |> Jason.decode!() == map
    end
  end

  describe "nothing is drawn that the look does not say" do
    property "the bodies, hearths, fires and places of a scene are those of the look" do
      check all(
              x <- StreamData.integer(30..225),
              y <- StreamData.integer(30..225),
              hour <- StreamData.integer(0..23),
              others <-
                StreamData.list_of({StreamData.integer(-70..70), StreamData.integer(-70..70)},
                  max_length: 4
                ),
              lit <-
                StreamData.list_of(StreamData.member_of(["town-hearth", "lodge-hearth"]),
                  max_length: 2
                ),
              max_runs: 40
            ) do
        region =
          ember({813, day: 220, hour: hour}, {x, y})
          |> add_bodies(others, {x, y})
          |> then(fn region -> Enum.reduce(lit, region, &light_up(&2, &1)) end)

        view = view(region)
        scene = Scene.build(view, @mira)
        look = Perception.look(view, @mira)

        ids = fn kind ->
          scene.things |> Enum.filter(&(&1.kind in kind)) |> Enum.map(& &1.id) |> Enum.sort()
        end

        assert ids.([:body]) == look.bodies |> Enum.map(& &1.id) |> Enum.sort()

        assert ids.([:hearth, :hearth_burning]) ==
                 look.hearths |> Enum.map(& &1.id) |> Enum.sort()

        assert ids.([:smoke, :glow]) == look.fires |> Enum.map(& &1.ref) |> Enum.sort()

        in_sight = fn place ->
          Space.distance(look.cell, place.cell) <= Perception.sight_cells(look.light)
        end

        here = List.wrap(look.here)
        expected = for place <- look.places ++ here, in_sight.(place), do: place.id
        assert ids.([:place]) == Enum.sort(expected)

        for thing <- scene.things do
          {ox, oy} = scene.origin
          {tx, ty} = thing.cell
          assert tx in ox..(ox + scene.size - 1) and ty in oy..(oy + scene.size - 1)
        end
      end
    end
  end

  describe "cost" do
    @describetag :perf

    test "a noon scene on the Ember Reach builds in a few milliseconds" do
      view = view(at_noon())
      Scene.build(view, @mira)

      times = for _run <- 1..30, do: elem(:timer.tc(fn -> Scene.build(view, @mira) end), 0)
      median = times |> Enum.sort() |> Enum.at(15)
      IO.puts("scene: #{Float.round(median / 1000, 2)} ms for a noon window of 101 by 101")

      assert median < 10_000
    end
  end

  # An entity that is a body with a position and a name, as Quire would make one.
  defp add_body(region, id, cell, glyph) do
    repr = %{name: String.capitalize(id), description: nil}
    repr = if glyph, do: Map.put(repr, :glyph, glyph), else: repr
    Region.put_entity(region, id, %{body: %{species: nil}, position: cell, repr: repr})
  end

  defp add_bodies(region, offsets, {x, y}) do
    offsets
    |> Enum.with_index()
    |> Enum.reduce(region, fn {{dx, dy}, n}, acc ->
      add_body(acc, "other-#{n}", {max(x + dx, 0), max(y + dy, 0)}, nil)
    end)
  end
end
