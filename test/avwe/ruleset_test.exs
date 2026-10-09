defmodule Avwe.RulesetTest do
  @moduledoc """
  A world's rules and the check on them (`Avwe.Ruleset`): the Earth-like set
  as the engine ships it, and small rules made for each way a set can be wrong.
  """

  use ExUnit.Case, async: true

  import Avwe.Test.RuleMaker

  alias Avwe.{Ruleset, SystemTable}

  # The order the systems have always run in, which the golden journal records.
  @legacy_order ~w(
    earthlike.daylight/step sim/miracles earthlike.weather/step earthlike.river/step
    earthlike.fire/step earthlike.heat/step play/movement play/waiting
    play/discovery play/autopilot earthlike.smoke/step play/memory
  )

  # Systems and rules made for the tests. Ids are all `test.ruleset.*`.
  defsystem(A1, "test.ruleset.a/step")
  defsystem(B, "test.ruleset.b/step")
  defsystem(D, "test.ruleset.zz_early/step")
  defsystem(E, "test.ruleset.first/one")
  defsystem(F, "test.ruleset.first/two")
  defsystem(G, "test.ruleset.late/step")
  defsystem(H, "test.ruleset.after_ping/step")
  defsystem(Y, "test.ruleset.ties_y/step")
  defsystem(Z, "test.ruleset.ties_z/step")
  defsystem(LX, "test.ruleset.loop_x/step")
  defsystem(LW, "test.ruleset.loop_w/step")
  defsystem(T1, "test.ruleset.twice/step")
  defsystem(O1, "test.ruleset.options/step")
  defsystem(W1, "test.ruleset.waits/step")

  defrule(RA, "test.ruleset.a",
    owns: [{:component, :shared}],
    provides: [:ping],
    systems: [{"step", A1}]
  )

  defrule(RB, "test.ruleset.b", owns: [{:component, :shared}, {:env, :own}])
  defrule(RC, "test.ruleset.c", conflicts: ["test.ruleset.d"])
  defrule(RD, "test.ruleset.d")
  defrule(RNeeds, "test.ruleset.needs", requires: [:ping], uses: [:pong])
  defrule(RWrongId, "test.ruleset.wrongid", systems: [{"step", B}])
  defrule(RFirst, "test.ruleset.first", systems: [{"one", E}, {"two", F}])

  defrule(RLate, "test.ruleset.late",
    runs_after: ["test.ruleset.first/two"],
    systems: [{"step", G}]
  )

  defrule(REarly, "test.ruleset.zz_early",
    runs_before: ["test.ruleset.first"],
    systems: [{"step", D}]
  )

  defrule(RTiesZ, "test.ruleset.ties_z", systems: [{"step", Z}])
  defrule(RTiesY, "test.ruleset.ties_y", systems: [{"step", Y}])

  defrule(RLoopX, "test.ruleset.loop_x",
    runs_after: ["test.ruleset.loop_w"],
    systems: [{"step", LX}]
  )

  defrule(RLoopW, "test.ruleset.loop_w",
    runs_after: ["test.ruleset.loop_x"],
    systems: [{"step", LW}]
  )

  # Waits on a rule that is in a loop, without being in it.
  defrule(RWaits, "test.ruleset.waits",
    runs_after: ["test.ruleset.loop_x"],
    systems: [{"step", W1}]
  )

  defrule(RTwice, "test.ruleset.twice", systems: [{"step", T1}, {"step", T1}])

  defrule(RBadPeriod, "test.ruleset.options", systems: [{"step", O1, every: 0}])
  defrule(RFloatPeriod, "test.ruleset.options", systems: [{"step", O1, every: 60.5}])
  defrule(RMisspelt, "test.ruleset.options", systems: [{"step", O1, evry: 60}])
  defrule(RPeriod, "test.ruleset.options", systems: [{"step", O1, every: 300}])

  defrule(RTypo, "test.ruleset.typo",
    runs_after: ["test.ruleset.nowhere/step", :nothing_provides_this]
  )

  defrule(RAfterPing, "test.ruleset.after_ping",
    runs_after: [:ping],
    systems: [{"step", H}]
  )

  defp ids(plan), do: Enum.map(plan.systems, & &1.id)

  defp problems(modules, opts \\ []) do
    assert {:error, problems} = Ruleset.plan(modules, opts)
    problems
  end

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

  describe "registering a plan" do
    test "lets a region run its systems by id, which the table did not know before" do
      {:ok, plan} = Ruleset.plan([RA])

      assert SystemTable.fetch("test.ruleset.a/step") == :error
      :ok = Ruleset.register(plan)

      assert SystemTable.fetch("test.ruleset.a/step") == {:ok, A1}
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

    test "all the problems at once, sorted" do
      problems = problems([RA, RB, RC, RD, RNeeds, RWrongId])

      assert problems == Enum.sort(problems)
      assert length(problems) == 3
    end

    test "two rules that own one key" do
      assert problems([RA, RB]) == [
               "the component shared is owned by both test.ruleset.a and test.ruleset.b; a rule " <>
                 "that wants to affect another's state feeds it through entities of its own or " <>
                 "through events"
             ]
    end

    test "rules that conflict" do
      assert problems([RC, RD]) == ["test.ruleset.c cannot run beside test.ruleset.d"]
      assert {:ok, _plan} = Ruleset.plan([RC])
    end

    test "a rule listed twice" do
      assert problems([RA, RA]) |> Enum.member?("the rule test.ruleset.a is listed twice")
    end

    test "a requirement that is met, and one that is only used" do
      assert {:ok, _plan} = Ruleset.plan([RA, RNeeds])

      assert problems([RNeeds], known: []) == [
               "test.ruleset.needs needs :ping, which no rule in this ruleset provides"
             ]
    end

    test "the hint names every rule that would provide it" do
      known = Enum.map([RA, RB], &Avwe.Rule.manifest/1)
      extra = %{Avwe.Rule.manifest(RB) | id: "test.ruleset.b2", provides: [:ping]}

      assert problems([RNeeds], known: known) == [
               "test.ruleset.needs needs :ping, which no rule in this ruleset provides " <>
                 "(test.ruleset.a does)"
             ]

      assert problems([RNeeds], known: [extra | known]) == [
               "test.ruleset.needs needs :ping, which no rule in this ruleset provides " <>
                 "(test.ruleset.a and test.ruleset.b2 do)"
             ]
    end

    test "a system module whose id is not its rule's" do
      assert problems([RWrongId]) == [
               "test.ruleset.wrongid lists its system step as Avwe.RulesetTest.B, " <>
                 "whose id is test.ruleset.b/step and not test.ruleset.wrongid/step"
             ]
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

  describe "what a rule says of its systems" do
    test "a system listed twice is a clash, not a loop" do
      assert problems([RTwice]) == ["test.ruleset.twice lists a system named step twice"]
    end

    test "a period is a whole number of seconds above 0" do
      assert problems([RBadPeriod]) == [
               "test.ruleset.options lists its system step with every: 0, which is not a " <>
                 "whole number of seconds above 0"
             ]

      assert problems([RFloatPeriod]) == [
               "test.ruleset.options lists its system step with every: 60.5, which is not a " <>
                 "whole number of seconds above 0"
             ]

      assert {:ok, plan} = Ruleset.plan([RPeriod])
      assert Ruleset.systems(plan) == [{"test.ruleset.options/step", [every: 300]}]
    end

    test "an option that a system does not have is refused, not ignored" do
      assert problems([RMisspelt]) == [
               "test.ruleset.options lists its system step with the option :evry, which a " <>
                 "system does not have (it has :every, :runs_after, :runs_before)"
             ]
    end
  end

  describe "order" do
    test "a rule's own systems run as it lists them, and others as they say" do
      {:ok, plan} = Ruleset.plan([RFirst, RLate, REarly])

      assert ids(plan) == [
               "test.ruleset.zz_early/step",
               "test.ruleset.first/one",
               "test.ruleset.first/two",
               "test.ruleset.late/step"
             ]
    end

    test "what no constraint settles is sorted by id, whatever order the rules were given in" do
      {:ok, plan} = Ruleset.plan([RTiesZ, RTiesY])
      {:ok, reversed} = Ruleset.plan([RTiesY, RTiesZ])

      assert ids(plan) == ["test.ruleset.ties_y/step", "test.ruleset.ties_z/step"]
      assert ids(reversed) == ids(plan)
    end

    test "a capability is a constraint on the systems of the rules that provide it" do
      {:ok, plan} = Ruleset.plan([RAfterPing, RA])

      assert ids(plan) == ["test.ruleset.a/step", "test.ruleset.after_ping/step"]
    end

    test "a constraint on a rule the ruleset does not have changes nothing" do
      known = [Avwe.Rule.manifest(RA)]

      assert {:ok, plan} = Ruleset.plan([RAfterPing], known: known)
      assert ids(plan) == ["test.ruleset.after_ping/step"]
    end

    test "constraints that cannot all be met" do
      assert problems([RLoopX, RLoopW]) == [
               "these systems each wait for another to run first, so none can: " <>
                 "test.ruleset.loop_w/step, test.ruleset.loop_x/step"
             ]
    end

    test "a system that only waits on a loop is not named as part of it" do
      assert problems([RLoopX, RLoopW, RWaits]) == [
               "these systems each wait for another to run first, so none can: " <>
                 "test.ruleset.loop_w/step, test.ruleset.loop_x/step"
             ]
    end

    test "a constraint that names nothing at all is a slip and not a rule left out" do
      assert problems([RTypo]) == [
               ~s(test.ruleset.typo must run in order with "test.ruleset.nowhere/step", which is no rule, system or capability),
               ~s(test.ruleset.typo must run in order with :nothing_provides_this, which is no rule, system or capability)
             ]
    end
  end
end
