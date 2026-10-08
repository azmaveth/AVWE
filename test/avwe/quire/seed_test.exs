defmodule Avwe.Quire.SeedTest do
  use ExUnit.Case, async: true

  alias Avwe.{Quire, Region}
  alias Avwe.Test.Fixtures

  setup do
    {:ok, world} = Quire.load(Fixtures.ember_reach())
    %{region: Quire.Seed.region(world, id: {0, 0}, seed: 1)}
  end

  test "every pin becomes a place on the grid", %{region: region} do
    assert Region.with_components(region, [:place]) ==
             ["ashwarden-lodge", "ember-reach", "the-dry-bend", "willow-docks"]

    # Ember Reach is pinned at 47.5% across, 54% down a 256-cell map.
    assert Region.get(region, "ember-reach", :position) == {121, 138}
    assert Region.get(region, "the-dry-bend", :repr).name == "The Dry Bend"
    assert Region.get(region, "the-dry-bend", :article) == "the-river-runs-dry"
  end

  test "characters start at home", %{region: region} do
    mira = Region.entity(region, "mira-vale")

    assert mira.home == "ember-reach"
    assert mira.position == Region.get(region, "ember-reach", :position)
    assert mira.body == %{species: "riverfolk"}
    assert mira.repr.name == "Mira Vale"
    assert mira.repr.description =~ "cartographer"
  end

  test "only characters get bodies", %{region: region} do
    assert Region.with_components(region, [:body]) == ["mira-vale"]
  end

  describe "a character whose home is not on the map" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      {:ok, world} = Quire.load(Fixtures.hollow_with_wanderers(dir))
      %{wanderers: world, region: Quire.Seed.region(world, id: {0, 0}, seed: 1)}
    end

    test "is named by unplaced/1, whether its home is an article without a pin or is missing",
         %{wanderers: world} do
      assert Quire.Seed.unplaced(world) == [
               %{id: "brine", name: "Brine", home: "The Salt Road"},
               %{id: "moth", name: "Moth", home: nil}
             ]
    end

    test "still has a body, with no position and no home", %{region: region} do
      for id <- ["brine", "moth"] do
        assert %{body: _body, repr: %{name: _name}} = Region.entity(region, id)
        assert Region.get(region, id, :position) == nil
        assert Region.get(region, id, :home) == nil
      end
    end

    test "leaves the placed characters where they were", %{region: region} do
      assert Region.get(region, "wren", :position) ==
               Region.get(region, "hollow-green", :position)

      assert Region.get(region, "odo", :position) == Region.get(region, "far-tower", :position)
    end

    test "is no one's business in a world where every character is placed" do
      {:ok, ember} = Quire.load(Fixtures.ember_reach())
      {:ok, hollow} = Quire.load(Fixtures.lantern_hollow())

      assert Quire.Seed.unplaced(ember) == []
      assert Quire.Seed.unplaced(hollow) == []
    end
  end
end
