defmodule Avwe.RulesTest do
  @moduledoc """
  The manifests of the rules the engine ships say what their systems touch; this
  runs the systems, from the states a real world is in, and checks it
  (`Avwe.RuleCase`, the model half of the conformance suite).
  """

  use ExUnit.Case, async: true

  alias Avwe.{Intent, Region, Rule, RuleCase, Ruleset}
  alias Avwe.Test.Ember

  @mira "mira-vale"
  @town "town-hearth"

  defp light(region, id) do
    hearth = Region.get(region, id, :hearth)
    Region.put_component(region, id, :hearth, %{hearth | burning: true, lit_at: region.time})
  end

  defp intent(region, verb, opts) do
    Region.submit(region, Intent.new(@mira, verb, Keyword.put_new(opts, :ref, "t-#{verb}")))
  end

  # Where a morning in the Ember Reach goes: Mira walks out under autopilot, the
  # town hearth burns and smokes, the ground warms.
  defp morning do
    Ember.region({813, day: 220, hour: 4}) |> light(@town)
  end

  # Mira under a controller, doing what a player does: speaking, writing,
  # lighting the hearth, walking, waiting.
  defp played do
    Ember.region({813, day: 220, hour: 9})
    |> Ember.controlled()
    |> intent(:say, params: %{text: "Hello.", volume: :talk}, ref: "t-say")
    |> intent(:kindle, ref: "t-kindle")
    |> intent(:go, target: "the-dry-bend", ref: "t-go")
    |> intent(:wait, params: %{for: 600}, ref: "t-wait")
  end

  # The hour before the river's source fails, and the failure.
  defp miracle do
    Ember.region({812, day: 200, hour: 14, minute: 50})
  end

  defp surveyed do
    for {region, steps} <- [{morning(), 240}, {played(), 120}, {miracle(), 25}],
        {id, keys} <- RuleCase.survey(region, steps),
        reduce: %{} do
      acc -> Map.update(acc, id, keys, &MapSet.union(&1, keys))
    end
  end

  setup_all do
    {:ok, plan} = Ruleset.plan_for(nil)
    %{plan: plan, written: surveyed()}
  end

  defp rule_of(plan, system_id) do
    Enum.find(plan.rules, fn rule -> Enum.any?(rule.systems, &(&1.id == system_id)) end)
  end

  test "a system writes only the keys its rule owns, or may edit", %{plan: plan, written: written} do
    for {id, keys} <- written do
      rule = rule_of(plan, id)

      allowed =
        case rule.edits do
          :any -> :any
          edits -> MapSet.new(rule.owns ++ edits)
        end

      stray = if allowed == :any, do: [], else: MapSet.difference(keys, allowed) |> Enum.to_list()

      assert stray == [], "#{id} wrote #{inspect(stray)}, which #{rule.id} does not own"
    end
  end

  test "the scenarios make the systems that move state write something", %{written: written} do
    for id <- ~w(
          earthlike.daylight/step earthlike.weather/step earthlike.river/step earthlike.fire/step
          earthlike.heat/step earthlike.smoke/step sim/miracles play/movement play/waiting
          play/autopilot play/memory
        ) do
      assert MapSet.size(written[id]) > 0, "#{id} wrote nothing in any scenario"
    end
  end

  test "a rule's manifest is what it declares, with defaults for the rest" do
    manifest = Rule.manifest(Avwe.Rules.Earthlike.Valley)

    assert manifest.id == "earthlike.valley"
    assert manifest.owns == [:terrain]
    assert manifest.systems == []
    assert manifest.requires == []
    assert manifest.edits == []
  end
end
