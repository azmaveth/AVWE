defmodule Avwe.TerrainTest do
  use ExUnit.Case, async: true

  alias Avwe.{Space, Terrain}
  alias Avwe.Terrain.Generator
  alias Avwe.Test.{Ember, Fixtures}

  setup_all do
    %{terrain: Ember.region().terrain, places: Ember.places()}
  end

  defp generate(seed) do
    spec = Fixtures.ember_reach_opts()[:terrain]

    places = %{
      "the-dry-bend" => {163, 78},
      "ember-reach" => {121, 138},
      "willow-docks" => {138, 162},
      "ashwarden-lodge" => {94, 105}
    }

    Generator.generate(spec, places, seed: seed, width: 256, height: 256)
  end

  describe "generation" do
    test "is repeatable from the seed" do
      assert generate(1) == generate(1)
      refute Terrain.source(generate(1)) == Terrain.source(generate(2))
    end

    test "the channel passes through the Dry Bend and the docks, and beside the town", %{
      terrain: terrain,
      places: places
    } do
      assert {_index, _cell, +0.0} = Terrain.nearest_channel(terrain, places.dry_bend)
      assert {_index, _cell, +0.0} = Terrain.nearest_channel(terrain, places.docks)
      assert {_index, _cell, town} = Terrain.nearest_channel(terrain, places.town)
      assert_in_delta town, 6, 0.5
    end

    test "the source is upstream of the Dry Bend, 450 to 700 m north-east of it", %{
      terrain: terrain,
      places: places
    } do
      source = Terrain.source(terrain)
      assert Space.meters(Space.distance(places.dry_bend, source)) in 450..700
      assert Space.direction(places.dry_bend, source) in ["north", "north-east", "east"]
      {bend, _cell, _distance} = Terrain.nearest_channel(terrain, places.dry_bend)
      assert bend > 0
    end

    test "the river leaves by the south edge", %{terrain: terrain} do
      assert {_x, 255} = terrain |> Terrain.channel() |> List.last()
    end

    test "the channel is continuous", %{terrain: terrain} do
      terrain
      |> Terrain.channel()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] -> assert Space.distance(a, b) < 1.5 end)
    end
  end

  describe "the land" do
    test "the channel bed only ever runs downhill", %{terrain: terrain} do
      heights = terrain |> Terrain.channel() |> Enum.map(&Terrain.elevation(terrain, &1))
      assert heights == Enum.sort(heights, :desc)
    end

    test "the lodge stands on a rise of grass above the town", %{terrain: terrain, places: places} do
      assert Terrain.elevation(terrain, places.lodge) >
               Terrain.elevation(terrain, places.town) + 10

      assert Terrain.ground(terrain, places.lodge) == :grass
    end

    test "ground follows the channel outward", %{terrain: terrain, places: places} do
      assert Terrain.ground(terrain, places.dry_bend) == :channel_bed
      assert Terrain.ground(terrain, places.docks) == :channel_bed
      assert Terrain.ground(terrain, places.town) == :clay

      {index, {x, y}, _distance} = Terrain.nearest_channel(terrain, places.town)
      assert index > 0
      assert Terrain.ground(terrain, {x - 4, y}) in [:silt, :clay]
    end
  end

  describe "paths" do
    test "upstream ends at the source and downstream at the exit", %{
      terrain: terrain,
      places: places
    } do
      {index, _cell, _distance} = Terrain.nearest_channel(terrain, places.town)
      channel = Terrain.channel(terrain)

      assert List.last(Terrain.path_along(terrain, index, :upstream)) == hd(channel)
      assert List.last(Terrain.path_along(terrain, index, :downstream)) == List.last(channel)
    end

    test "reaches cover the channel in order", %{terrain: terrain} do
      reaches = Terrain.reaches(terrain)
      assert hd(reaches).first == 0
      assert List.last(reaches).last == length(Terrain.channel(terrain)) - 1
      assert Enum.map(reaches, & &1.first) == Enum.sort(Enum.map(reaches, & &1.first))
      assert Enum.all?(reaches, &(&1.length_m >= 90 and &1.length_m <= 150))
    end
  end

  test "terrain without a river is level grass" do
    terrain = Generator.generate([], %{}, seed: 1, width: 64, height: 64)
    refute Terrain.river?(terrain)
    assert Terrain.nearest_channel(terrain, {5, 5}) == nil
    assert Terrain.ground(terrain, {5, 5}) == :grass
  end
end
