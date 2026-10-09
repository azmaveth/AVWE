defmodule Avwe.E2E.RulesetTest do
  @moduledoc """
  End to end through the public API: a world runs the systems of its rules, a
  definition can leave a rule out, and one whose rules do not make a world is
  refused in words before anything starts.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures, only: [ember_reach_definition: 0]

  alias Avwe.{Definition, Ruleset}

  @world :ember_ruleset
  @region {0, 0}

  defp systems(world) do
    [{pid, _table}] = Registry.lookup(Avwe.Registry, {:region, world, @region})
    :sys.get_state(pid).region.systems |> Enum.map(&elem(&1, 0))
  end

  defp stopping(world), do: on_exit(fn -> Avwe.stop_world(world) end)

  test "a world with no ruleset runs the Earth-like systems, in the old order" do
    {:ok, _pid} = Avwe.start_world(@world, definition: ember_reach_definition())
    stopping(@world)

    assert systems(@world) == [
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

    assert Enum.map(Avwe.default_systems(), &elem(&1, 0)) == systems(@world)
  end

  test "a definition that leaves a rule out runs without its systems" do
    definition = %{
      ember_reach_definition()
      | ruleset: [preset: "earthlike", without: ["earthlike.smoke"]]
    }

    {:ok, _pid} = Avwe.start_world(@world, definition: definition)
    stopping(@world)

    refute "earthlike.smoke/step" in systems(@world)
    assert "earthlike.fire/step" in systems(@world)

    Avwe.step(@world, 10)
    assert {:ok, %{fields: fields}} = Avwe.snapshot(@world)
    refute Map.has_key?(fields, :smoke)
  end

  test "a definition whose rules do not make a world does not start, and says why" do
    definition = %{
      ember_reach_definition()
      | ruleset: [preset: "earthlike", without: ["earthlike.weather"]]
    }

    assert {:error, {:invalid_ruleset, problems} = reason} =
             Avwe.start_world(@world, definition: definition)

    assert Avwe.World.whereis(@world) == nil

    assert ("earthlike.river needs :air_temperature, which no rule in this ruleset provides " <>
              "(earthlike.weather does)") in problems

    assert Definition.explain(reason) =~
             "the world's rules do not make a world:\n  earthlike.heat needs :air_temperature"
  end

  test "the same ruleset always gives the same plan" do
    plans = for _n <- 1..5, do: Ruleset.plan_for(nil)

    assert plans |> Enum.uniq() |> length() == 1
  end
end
