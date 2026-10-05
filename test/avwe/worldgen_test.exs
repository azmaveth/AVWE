defmodule Avwe.WorldgenTest do
  use ExUnit.Case, async: true

  alias Avwe.Region
  alias Avwe.Systems.{Fire, Miracles}
  alias Avwe.Test.{Ember, Fixtures}

  @camp [id: "camp", at: "ember-reach", name: "a camp fire", fuel_kg: 2.0, power_w: 1_000.0]
  @coal "the-last-coal"

  defp build(overrides),
    do: Ember.region({813, day: 220, hour: 4}, [systems: [Miracles, Fire]] ++ overrides)

  defp with_coal(changes) do
    miracles =
      Enum.map(Fixtures.ember_reach_opts()[:miracles], fn miracle ->
        if miracle[:id] == @coal, do: Keyword.merge(miracle, changes), else: miracle
      end)

    build(miracles: miracles)
  end

  describe "hearths" do
    test "take their numbers from the config, as floats, and start cold" do
      region = build(hearths: [@camp])

      assert %{fuel_kg: 2.0, power_w: 1.0e3, burning: false, last_step: last_step} =
               Region.get(region, "camp", :hearth)

      assert last_step == Fire.zero_step()
      assert Region.get(region, "camp", :position) == Ember.places().town
    end

    test "may start empty, and burn down without a crash" do
      region = build(hearths: [Keyword.put(@camp, :fuel_kg, 0)])
      assert Region.get(region, "camp", :hearth).fuel_kg == 0.0

      lit =
        Region.put_component(region, "camp", :hearth, %{
          Region.get(region, "camp", :hearth)
          | burning: true
        })

      assert %{burning: false, fuel_kg: +0.0} =
               Region.get(Region.advance(lit, 1), "camp", :hearth)
    end

    test "refuse a power of zero or less, which the fire system would divide by" do
      for power <- [0.0, 0, -5.0] do
        assert_raise ArgumentError, ~r/hearth "camp": power_w must be above 0/, fn ->
          build(hearths: [Keyword.put(@camp, :power_w, power)])
        end
      end
    end

    test "refuse negative fuel" do
      assert_raise ArgumentError, ~r/hearth "camp": fuel_kg must be at least 0/, fn ->
        build(hearths: [Keyword.put(@camp, :fuel_kg, -1.0)])
      end
    end
  end

  describe "standing miracles" do
    test "are lit hearths that carry no smoke setting" do
      region = build([])
      assert %{burning: true, fuel_kg: +0.0, power_w: 800.0} = Region.get(region, @coal, :hearth)

      assert %{kind: :standing, heat_w: 800.0, breaks: [:fuel, :dousing]} =
               miracle = Region.get(region, @coal, :miracle)

      refute Map.has_key?(miracle, :smoke)
    end

    test "must give heat, and are blamed as what the config calls them" do
      assert_raise ArgumentError,
                   ~r/^standing miracle "the-last-coal": heat_w must be above 0/,
                   fn ->
                     with_coal(heat_w: 0.0)
                   end
    end
  end
end
