defmodule Avwe.GroundMapTest do
  use ExUnit.Case, async: true

  alias Avwe.{GroundCache, GroundMap, Terrain}
  alias Avwe.Test.Ember

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

  describe "a ground map" do
    test "holds a byte for each cell, and says what a cell is, or nil off the map" do
      map = GroundMap.new(3, 2, <<0, 1, 2, 3, 4, 5>>)

      assert GroundMap.at(map, {0, 0}) == :grass
      assert GroundMap.at(map, {2, 0}) == :clay
      assert GroundMap.at(map, {0, 1}) == :stone
      assert GroundMap.at(map, {2, 1}) == :channel_bed

      for off <- [{-1, 0}, {3, 0}, {0, -1}, {0, 2}, {99, 99}],
          do: assert(GroundMap.at(map, off) == nil)
    end

    test "has exactly width times height cells" do
      assert_raise ArgumentError, ~r/a 3 by 2 ground map takes 6 cells, got 5/, fn ->
        GroundMap.new(3, 2, <<0, 0, 0, 0, 0>>)
      end
    end

    test "names its grounds by byte, both ways" do
      for kind <- GroundMap.kinds() do
        assert kind |> GroundMap.code() |> GroundMap.kind() == kind
      end

      assert GroundMap.kind(6) == nil
      assert GroundMap.kinds() == ~w(grass silt clay stone reeds channel_bed)a
    end

    test "gives a piece of a row, with nil for what is off the map" do
      map = GroundMap.new(3, 2, <<0, 1, 2, 3, 4, 5>>)

      assert GroundMap.slice(map, 1, 0, 3) == [:stone, :reeds, :channel_bed]
      assert GroundMap.slice(map, 0, 1, 4) == [:silt, :clay, nil, nil]
      assert GroundMap.slice(map, 5, 0, 2) == [nil, nil]
      assert GroundMap.slice(map, 0, 0, 0) == []
    end
  end

  describe "Terrain.ground_map/1" do
    defp assert_agrees(terrain) do
      map = Terrain.ground_map(terrain)
      assert {map.width, map.height} == {terrain.width, terrain.height}

      for y <- 0..(terrain.height - 1), x <- 0..(terrain.width - 1) do
        assert GroundMap.at(map, {x, y}) == Terrain.ground(terrain, {x, y}), "cell #{x},#{y}"
      end

      map
    end

    test "agrees with ground/2 on every cell of a small land that has every kind of ground" do
      map = assert_agrees(small())

      kinds = for y <- 0..29, x <- 0..39, uniq: true, do: GroundMap.at(map, {x, y})
      assert Enum.sort(kinds) == Enum.sort(GroundMap.kinds())
    end

    test "agrees with ground/2 on every cell of the Ember Reach" do
      assert_agrees(Ember.region().terrain)
    end

    test "is the same every time, and differs for a different land" do
      assert Terrain.ground_map(small()) == Terrain.ground_map(small())
      refute Terrain.ground_map(small(3)) == Terrain.ground_map(small(4))
    end
  end

  describe "the cache" do
    test "builds the map of a terrain the first time it is asked for, and keeps it" do
      terrain = small(11)
      refute GroundCache.cached?(terrain)

      assert GroundCache.fetch(terrain) == Terrain.ground_map(terrain)
      assert GroundCache.cached?(terrain)
      assert GroundCache.fetch(terrain) == GroundCache.fetch(terrain)
    end

    test "shares one map between terrains that are equal, and keeps different lands apart" do
      assert GroundCache.fetch(small(12)) == GroundCache.fetch(small(12))
      refute GroundCache.fetch(small(12)) == GroundCache.fetch(small(13))
    end

    test "gives every caller the same map when many ask at once for a terrain nobody has built" do
      terrain = small(14)

      maps =
        1..8
        |> Enum.map(fn _n -> Task.async(fn -> GroundCache.fetch(terrain) end) end)
        |> Enum.map(&Task.await(&1, 30_000))

      assert Enum.uniq(maps) == [Terrain.ground_map(terrain)]
    end
  end
end
