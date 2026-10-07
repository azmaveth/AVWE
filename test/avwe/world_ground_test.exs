defmodule Avwe.WorldGroundTest do
  use ExUnit.Case, async: true

  alias Avwe.{GroundCache, GroundMap, Region, Rle, Scene, Terrain, WorldGround}
  alias Avwe.Test.Ember

  @mira "mira-vale"
  @dry_bend {163, 78}
  @letters %{
    grass: "g",
    silt: "s",
    clay: "c",
    stone: "t",
    reeds: "r",
    channel_bed: "b"
  }

  # A small land with every kind of ground: a channel running south, a stony
  # rise and a patch of clay.
  defp small(seed \\ 3) do
    Terrain.new(
      width: 40,
      height: 30,
      seed: seed,
      channel: for(y <- 2..27, do: {18 + div(y, 9), y}),
      rises: [%{center: {5, 5}, height_m: 60.0, radius_cells: 6}],
      clay: [%{center: {30, 20}, radius_cells: 3}]
    )
  end

  defp world_ground(terrain), do: WorldGround.build(terrain, GroundCache.fetch(terrain))

  defp bed_cells(%GroundMap{width: width, height: height} = map) do
    for y <- 0..(height - 1),
        x <- 0..(width - 1),
        GroundMap.at(map, {x, y}) == :channel_bed,
        do: {x, y}
  end

  describe "the rows" do
    test "are one for each row of the map, as wide as the map" do
      terrain = small()
      ground = world_ground(terrain)

      assert ground.width == 40 and ground.height == 30
      assert length(ground.rows) == 30
      for row <- ground.rows, do: assert(length(Rle.decode(row)) == 40)
    end

    test "say what the ground map says of every cell, in the letters of a body's scene" do
      terrain = small()
      map = GroundCache.fetch(terrain)
      ground = world_ground(terrain)

      for {row, y} <- Enum.with_index(ground.rows),
          {letter, x} <- Enum.with_index(Rle.decode(row)) do
        assert letter == @letters[GroundMap.at(map, {x, y})], inspect({x, y})
      end
    end

    test "hold every kind of ground the land has, and never water" do
      letters = small() |> world_ground() |> Map.fetch!(:rows) |> Enum.flat_map(&Rle.decode/1)

      assert letters |> Enum.uniq() |> Enum.sort() == ~w(b c g r s t)
    end
  end

  describe "the reaches" do
    test "are one for each reach of the river, and hold every bed cell once between them" do
      terrain = small()
      ground = world_ground(terrain)

      assert length(ground.reaches) == length(Terrain.reaches(terrain))
      assert length(ground.reaches) > 1

      cells = Enum.concat(ground.reaches)
      assert length(cells) == length(Enum.uniq(cells))
      assert Enum.sort(cells) == Enum.sort(bed_cells(GroundCache.fetch(terrain)))
    end

    test "hold each bed cell in the reach of the channel point nearest it, in reading order" do
      terrain = small()
      ground = world_ground(terrain)

      for {cells, reach} <- Enum.with_index(ground.reaches) do
        assert cells == Enum.sort_by(cells, fn {x, y} -> {y, x} end)

        for cell <- cells do
          {index, _point, _distance} = Terrain.nearest_channel(terrain, cell)
          assert Terrain.reach_of(terrain, index) == reach, inspect(cell)
        end
      end
    end

    test "are none for a land with no river" do
      terrain = Terrain.new(width: 8, height: 6, seed: 1)
      ground = world_ground(terrain)

      assert ground.reaches == []
      assert length(ground.rows) == 6
    end
  end

  describe "against a body's scene" do
    # The river runs, in the town's own year before the source fails; and it
    # does not once it has. A bed cell is water in a body's scene where its
    # reach runs, so the two must agree about which reach each cell is in.
    defp scene_view(region) do
      region
      |> Region.view()
      |> Map.put(:terrain, region.terrain)
      |> Map.put(:ground, GroundCache.fetch(region.terrain))
    end

    defp running?(region, reach) do
      region
      |> Region.get("river", :river)
      |> Map.fetch!(:reaches)
      |> elem(reach)
      |> Map.fetch!(:silent)
      |> Kernel.not()
    end

    for {name, at} <- [
          {"before the source fails", {812, day: 190, hour: 12}},
          {"after it", {813, day: 220, hour: 12}}
        ] do
      test "agrees with which reach runs, #{name}" do
        region =
          unquote(Macro.escape(at))
          |> Ember.region()
          |> Ember.controlled()
          |> Region.put_component(@mira, :position, @dry_bend)

        ground = world_ground(region.terrain)
        scene = region |> scene_view() |> Scene.build(@mira)

        seen =
          for {cells, reach} <- Enum.with_index(ground.reaches),
              cell <- cells,
              kind = Scene.kind_at(scene, cell),
              do: {kind, running?(region, reach), cell}

        assert seen != []

        for {kind, running, cell} <- seen do
          assert kind == if(running, do: :water, else: :channel_bed), inspect(cell)
        end
      end
    end

    test "the river runs somewhere before the source fails, so the check above is not empty" do
      region = Ember.region({812, day: 190, hour: 12})
      reaches = region |> Region.get("river", :river) |> Map.fetch!(:reaches) |> Tuple.to_list()

      assert Enum.any?(reaches, &(not &1.silent))
    end
  end

  describe "as plain data" do
    test "is JSON, with a cell as [x, y]" do
      terrain = small()
      map = terrain |> world_ground() |> WorldGround.to_map()

      assert map |> Jason.encode!() |> Jason.decode!() == map
      assert Map.keys(map) |> Enum.sort() == ["height", "reaches", "rows", "width"]
      assert [[_x, _y] | _] = hd(map["reaches"])
    end
  end

  describe "the cache" do
    test "builds the world ground of a terrain the first time it is asked for, and keeps it" do
      terrain = small(21)
      refute GroundCache.world_cached?(terrain)

      ground = GroundCache.world(terrain)

      assert ground == world_ground(terrain)
      assert GroundCache.world_cached?(terrain)
      assert GroundCache.world(terrain) == ground
    end

    test "builds the ground map with it, and keeps lands apart" do
      terrain = small(22)
      refute GroundCache.cached?(terrain)

      GroundCache.world(terrain)

      assert GroundCache.cached?(terrain)
      refute GroundCache.world(small(22)) == GroundCache.world(small(23))
    end

    test "gives every caller the same ground when many ask at once for a land nobody has built" do
      terrain = small(24)

      grounds =
        1..8
        |> Enum.map(fn _n -> Task.async(fn -> GroundCache.world(terrain) end) end)
        |> Enum.map(&Task.await(&1, 30_000))

      assert Enum.uniq(grounds) == [world_ground(terrain)]
    end
  end
end
