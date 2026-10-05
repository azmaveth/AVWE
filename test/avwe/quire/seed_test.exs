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
end
