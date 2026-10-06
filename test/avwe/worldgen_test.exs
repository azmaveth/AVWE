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

  describe "climate" do
    test "takes the wind from the config and refuses a direction off the compass" do
      assert build(climate: [wind: [from: "north-east", m_s: 0]]).env.wind ==
               %{from: "north-east", m_s: 0.0}

      for from <- ["up", "northeast", "North", nil] do
        assert_raise ArgumentError, ~r/^wind: from must be one of north, north-east, /, fn ->
          build(climate: [wind: [from: from, m_s: 2.0]])
        end
      end
    end

    test "refuses a wind blowing backwards" do
      assert_raise ArgumentError, ~r/^wind: m_s must be at least 0, got -1.0/, fn ->
        build(climate: [wind: [from: "north", m_s: -1]])
      end
    end
  end

  describe "characters" do
    @walk [at: "04:30", do: {:go, target: "the-dry-bend"}, note: "walks the banks before dawn"]

    defp with_mira(spec), do: build(characters: ["mira-vale": spec])

    test "every body gets autopilot and control components, and the named ones their routine" do
      region = build([])

      assert Region.get(region, "mira-vale", :autopilot) == Avwe.Autopilot.fresh()
      assert Region.get(region, "mira-vale", :control) == %{holder: nil, since: nil}
      assert Region.get(region, "mira-vale", :norms) == [:invited_fire]

      assert [
               %{
                 at: 16_200,
                 do: [{:go, target: "the-dry-bend"}, {:wait, params: %{for: 2400}}, {:go, _}],
                 note: _walk
               },
               %{at: 28_800, do: [_, {:wait, params: %{for: 10_800}}, _], note: "the survey"},
               %{at: 64_800, do: [{:go, target: "ashwarden-lodge"}, _, _]},
               %{at: 79_200, do: [{:go, target: "ember-reach"}, {:rest}], note: nil}
             ] = Region.get(region, "mira-vale", :routine)
    end

    test "sort the routine by time, and leave unnamed bodies without one" do
      region = with_mira(routine: [[at: "22:00", do: {:rest}], @walk])

      # A single step is a plan of one.
      assert [%{at: 16_200, do: [{:go, target: "the-dry-bend"}]}, %{at: 79_200, do: [{:rest}]}] =
               Region.get(region, "mira-vale", :routine)

      assert Region.get(region, "mira-vale", :norms) == nil

      assert Region.get(build(characters: []), "mira-vale", :routine) == nil
      assert Region.get(build(characters: []), "mira-vale", :autopilot) == Avwe.Autopilot.fresh()
    end

    test "refuse a time that is not HH:MM" do
      for at <- ["4:30", "04:30:00", "24:00", "04:60", "dawn", 16_200, nil] do
        assert_raise ArgumentError, ~r/^character "mira-vale": at must be "HH:MM", got /, fn ->
          with_mira(routine: [Keyword.put(@walk, :at, at)])
        end
      end
    end

    test "refuse a body that is not there, a do that is not a verb, and norms that are not atoms" do
      assert_raise ArgumentError, ~r/^character "nobody": no such body/, fn ->
        build(characters: [nobody: [routine: [@walk]]])
      end

      assert_raise ArgumentError,
                   ~r/^character "mira-vale": do must be a step or a list of steps, got "go"/,
                   fn ->
                     with_mira(routine: [Keyword.put(@walk, :do, "go")])
                   end

      assert_raise ArgumentError,
                   ~r/^character "mira-vale": do must be a step or a list of steps, got \[\]/,
                   fn ->
                     with_mira(routine: [Keyword.put(@walk, :do, [])])
                   end

      for step <- ["go", {"go", []}, {:go, %{}}] do
        assert_raise ArgumentError,
                     ~r/^character "mira-vale": a step must be {verb, opts}, got /,
                     fn ->
                       with_mira(routine: [Keyword.put(@walk, :do, [{:go, target: "x"}, step])])
                     end
      end

      assert_raise ArgumentError,
                   ~r/^character "mira-vale": norms must be atoms, got \["fire"\]/,
                   fn ->
                     with_mira(norms: ["fire"])
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
