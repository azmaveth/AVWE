defmodule Avwe.EarthlikeRulesetTest do
  @moduledoc """
  The Earth-like set of rules as the engine ships it, checked by the kernel's
  `Avwe.Ruleset`: the order its systems run in, what a definition may add and leave
  out of it, and what is said when a rule is missing. (The check itself is tested
  in the kernel's project, with rules made for the purpose.)
  """

  use ExUnit.Case, async: true

  alias Avwe.{Ruleset, SystemTable}

  # The order the systems have always run in, which the golden journal records.
  @legacy_order ~w(
    earthlike.daylight/step sim/miracles earthlike.weather/step earthlike.river/step
    earthlike.fire/step earthlike.heat/step play/movement play/waiting
    play/discovery play/autopilot earthlike.smoke/step play/memory
  )

  defp ids(plan), do: Enum.map(plan.systems, & &1.id)

  describe "the Earth-like ruleset" do
    test "is what a definition without a ruleset runs, and its systems run in the old order" do
      assert {:ok, plan} = Ruleset.plan_for(nil)

      assert ids(plan) == @legacy_order

      assert Enum.map(plan.rules, & &1.id) |> Enum.sort() ==
               plan.rules |> Enum.map(& &1.id) |> Enum.sort()

      assert "sim" in Enum.map(plan.rules, & &1.id)
      assert Ruleset.systems(plan) == Enum.map(@legacy_order, &{&1, []})
    end

    test "the plan's modules are the ones the engine has always run" do
      {:ok, plan} = Ruleset.plan_for(nil)

      assert Enum.map(plan.systems, & &1.module) == [
               Avwe.Systems.Daylight,
               Avwe.Systems.Miracles,
               Avwe.Systems.Weather,
               Avwe.Systems.River,
               Avwe.Systems.Fire,
               Avwe.Systems.Heat,
               Avwe.Systems.Movement,
               Avwe.Systems.Waiting,
               Avwe.Systems.Discovery,
               Avwe.Systems.Autopilot,
               Avwe.Systems.Smoke,
               Avwe.Systems.Memory
             ]
    end

    test "every system of the plan is known to the table" do
      {:ok, plan} = Ruleset.plan_for(nil)

      assert SystemTable.fetch("earthlike.heat/step") == {:ok, Avwe.Systems.Heat}
      assert SystemTable.missing(@legacy_order) == []
      assert Enum.all?(plan.systems, &(SystemTable.fetch(&1.id) == {:ok, &1.module}))
    end

    test "leaves a rule out when it is not needed: a world with no smoke" do
      assert {:ok, plan} = Ruleset.plan_for(%{preset: "earthlike", without: ["earthlike.smoke"]})

      assert ids(plan) == @legacy_order -- ["earthlike.smoke/step"]
    end

    test "owns what the systems write: no two rules own one key, and every rule is in order" do
      {:ok, plan} = Ruleset.plan_for(nil)

      assert plan.owners[{:field, :heat}] == "earthlike.heat"
      assert plan.owners[{:component, :hearth}] == "earthlike.fire"
      assert plan.owners[:terrain] == "earthlike.valley"
      assert plan.providers[:air_temperature] == ["earthlike.weather"]
    end
  end

  describe "refusing a ruleset, in words" do
    test "a rule whose need nothing provides, and what would" do
      assert {:error, problems} =
               Ruleset.plan_for(%{preset: "earthlike", without: ["earthlike.weather"]})

      assert ("earthlike.heat needs :air_temperature, which no rule in this ruleset provides " <>
                "(earthlike.weather does)") in problems

      assert ("earthlike.river needs :air_temperature, which no rule in this ruleset provides " <>
                "(earthlike.weather does)") in problems

      assert ("earthlike.smoke needs :wind, which no rule in this ruleset provides " <>
                "(earthlike.weather does)") in problems

      assert ("earthlike.heat needs :sky_temperature, which no rule in this ruleset provides " <>
                "(earthlike.weather does)") in problems
    end

    test "an unknown rule or preset in what a definition says" do
      assert {:error, [message]} =
               Ruleset.resolve(%{preset: "earthlike", with: ["earthlike.fyre"]})

      assert message =~ ~s(no rule has the id "earthlike.fyre")
      assert message =~ ~s("earthlike.fire")

      assert {:error, [message]} = Ruleset.resolve(%{preset: "medieval"})
      assert message =~ ~s(no ruleset preset is named "medieval")
      assert message =~ ~s("earthlike")
    end
  end

  describe "what a definition says of its rules" do
    test "a rule left out that no rule has is refused, as one added is" do
      assert {:error, [message]} =
               Ruleset.resolve(%{preset: "earthlike", without: ["earthlike.smok"]})

      assert message =~ ~s(no rule has the id "earthlike.smok")
    end

    test "the engine's own rule cannot be left out" do
      assert Ruleset.resolve(%{preset: "earthlike", without: ["sim"]}) ==
               {:error, ["sim always runs and cannot be left out"]}
    end

    test "a rule added and left out at once is refused, not guessed" do
      spec = %{preset: "earthlike", with: ["earthlike.fire"], without: ["earthlike.fire"]}

      assert Ruleset.resolve(spec) == {:error, ["earthlike.fire is both added and left out"]}
    end

    test "a rule added that the preset has, or listed twice, is still one rule" do
      {:ok, plain} = Ruleset.plan_for(%{preset: "earthlike"})
      {:ok, added} = Ruleset.plan_for(%{preset: "earthlike", with: ["earthlike.fire"]})
      {:ok, twice} = Ruleset.plan_for(%{rules: ["play", "play", "earthlike.daylight"]})

      assert ids(added) == ids(plain)

      assert Enum.sort(ids(twice)) ==
               Enum.sort([
                 "earthlike.daylight/step",
                 "sim/miracles",
                 "play/movement",
                 "play/waiting",
                 "play/discovery",
                 "play/autopilot",
                 "play/memory"
               ])
    end

    test "what is left out is left out, once or however often the preset says it" do
      {:ok, plan} = Ruleset.plan_for(%{preset: "earthlike", without: ["earthlike.smoke"]})

      refute "earthlike.smoke/step" in ids(plan)
    end

    test "a ruleset may be given as a keyword list, as a definition keeps it" do
      assert Ruleset.plan_for(preset: "earthlike", without: ["earthlike.smoke"]) ==
               Ruleset.plan_for(%{preset: "earthlike", without: ["earthlike.smoke"]})
    end
  end
end
