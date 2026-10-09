defmodule Avwe.RulesCompositionTest do
  @moduledoc """
  Leaving rules out must not change the physics of those that remain. Of every
  set of the Earth-like rules that the check accepts, the plan runs the systems
  that are left in the order the engine has always run them, or in another that
  makes the same world: the systems it puts in another order do not depend on
  each other. A rule that read another's state without saying which runs first
  would show here, as a world that differs.
  """

  use ExUnit.Case, async: true

  alias Avwe.{Region, Ruleset}
  alias Avwe.Test.Ember

  # The order the Ember Reach's systems have always run in.
  @legacy [
    "earthlike.daylight/step",
    "sim/miracles",
    "earthlike.weather/step",
    "earthlike.river/step",
    "earthlike.fire/step",
    "earthlike.heat/step",
    "play/movement",
    "play/waiting",
    "play/discovery",
    "play/autopilot",
    "earthlike.smoke/step",
    "play/memory"
  ]

  # What a system reads of another's state in a step, so that the other runs first:
  # {runs first, then reads it}. The scenarios below find a dependency that is
  # missing here only if they happen to exercise it; this says them all.
  @flows [
    {"sim/miracles", "earthlike.river/step"},
    {"sim/miracles", "earthlike.fire/step"},
    {"earthlike.weather/step", "earthlike.heat/step"},
    {"earthlike.weather/step", "earthlike.smoke/step"},
    {"earthlike.river/step", "earthlike.heat/step"},
    {"earthlike.fire/step", "earthlike.heat/step"},
    {"earthlike.fire/step", "earthlike.smoke/step"},
    # The bodies act on the world as the physics left it.
    {"earthlike.daylight/step", "play/movement"},
    {"earthlike.weather/step", "play/movement"},
    {"earthlike.river/step", "play/movement"},
    {"earthlike.fire/step", "play/movement"},
    {"earthlike.heat/step", "play/movement"},
    # And smell is judged where they ended up, before the step is remembered.
    {"play/autopilot", "earthlike.smoke/step"},
    {"earthlike.smoke/step", "play/memory"}
  ]

  # Every set of the preset's rules (play among them) that makes a world.
  defp accepted do
    ids = Ruleset.presets()["earthlike"]

    for mask <- 0..(Bitwise.bsl(1, length(ids)) - 1),
        subset =
          for({id, n} <- Enum.with_index(ids), Bitwise.band(mask, Bitwise.bsl(1, n)) != 0, do: id),
        {:ok, plan} <- [Ruleset.plan_for(%{rules: subset})] do
      {subset, Enum.map(plan.systems, & &1.id)}
    end
  end

  # A morning with the town hearth lit, and the hour the river's source fails.
  defp morning(systems) do
    region = Ember.region({813, day: 220, hour: 4}, systems: systems)
    hearth = Region.get(region, "town-hearth", :hearth)

    region
    |> Region.put_component("town-hearth", :hearth, %{hearth | burning: true, lit_at: region.time})
    |> Region.advance(60)
  end

  defp miracle(systems) do
    {812, day: 200, hour: 14, minute: 50} |> Ember.region(systems: systems) |> Region.advance(25)
  end

  defp worlds(ids) do
    systems = Enum.map(ids, &{&1, []})

    for region <- [morning(systems), miracle(systems)],
        do: Region.state_hash(%{region | systems: []})
  end

  test "the check accepts many sets of the Earth-like rules, and the whole set is the old order" do
    accepted = accepted()

    assert length(accepted) > 50
    assert {Ruleset.presets()["earthlike"], @legacy} in accepted
  end

  test "every set the check accepts runs a system after the systems whose state it reads" do
    for {subset, planned} <- accepted(),
        {first, then} <- @flows,
        first in planned,
        then in planned do
      assert Enum.find_index(planned, &(&1 == first)) < Enum.find_index(planned, &(&1 == then)),
             "#{inspect(subset)} runs #{then} before #{first}, whose state it reads"
    end
  end

  test "every set the check accepts makes the world the old order makes of the rules that remain" do
    for {subset, planned} <- accepted(),
        wanted = Enum.filter(@legacy, &(&1 in planned)),
        planned != wanted do
      assert worlds(planned) == worlds(wanted),
             "#{inspect(subset)} runs #{inspect(planned)} and not #{inspect(wanted)}, " <>
               "and they make different worlds"
    end
  end
end
