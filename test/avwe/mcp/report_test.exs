defmodule Avwe.MCP.ReportTest do
  use ExUnit.Case, async: true

  alias Avwe.{Calendar, Percept}
  alias Avwe.MCP.Report

  @now Calendar.at(813, day: 220, hour: 9)

  defp report(status, opts \\ []) do
    %{
      status: status,
      percepts: Keyword.get(opts, :percepts, []),
      plan: Keyword.get(opts, :plan, []),
      action: Keyword.get(opts, :action),
      dropped: 0
    }
  end

  test "a yielded plan says the routine took the body back and the plan is over" do
    action = %{ref: "m-1", verb: :go, target: "the-dry-bend"}
    text = Report.text(report(:yielded, action: action), @now)

    assert text =~
             ~r/^Yielded: your routine took the body back while you were away from the keyboard, and your plan is over\./

    assert text =~ "Your routine has the body, in the middle of: go to the-dry-bend."
    assert text =~ "Act again to take the body back."
    refute text =~ "Under way"
    assert %{status: :yielded} = Report.data(report(:yielded), @now)
  end

  test "with a look, places and hearths go by name and a wait says when it ends" do
    look = %{
      time: @now,
      here: %{id: "ember-reach", name: "Ember Reach"},
      places: [%{id: "the-dry-bend", name: "The Dry Bend"}],
      hearths: [%{id: "town-hearth", name: "the kiln-house hearth"}],
      action: %{ref: "m-2", verb: :wait, target: nil, params: %{for: 1_200}, until: @now + 1_200}
    }

    going = %{ref: "m-1", verb: :go, target: "the-dry-bend"}
    plan = [{:kindle, [target: "town-hearth"]}, {:go, [target: "ember-reach"]}]
    text = Report.text(report(:still_going, action: going, plan: plan), @now, look)
    assert text =~ "Under way: go to The Dry Bend."
    assert text =~ "Planned after it: kindle the kiln-house hearth, go to Ember Reach."

    waiting = %{ref: "m-2", verb: :wait, target: nil}

    assert Report.text(report(:still_going, action: waiting), @now, look) =~
             "Under way: wait until 09:20."

    assert %{action: %{until: "813 AR, day 220, 09:20"}} =
             Report.data(report(:still_going, action: waiting), @now, look)

    # Another action's end is not this one's.
    other = %{ref: "m-3", verb: :wait, target: nil}
    assert Report.text(report(:still_going, action: other), @now, look) =~ "Under way: wait."
  end

  test "a plan of more than three steps left shows three and how many more" do
    plan =
      [{:go, [target_name: "Mill Pond"]}, {:wait, [params: %{for: 7_200}]}] ++
        List.duplicate({:say, [params: %{text: "Hello."}]}, 6)

    text = Report.text(report(:still_going, plan: plan), @now)
    assert text =~ "Planned after it: go to Mill Pond, wait 2 hours, say, and 5 more."

    three = Enum.take(plan, 3)
    assert Report.text(report(:still_going, plan: three), @now) =~ ~r/wait 2 hours, say\.$/
  end

  test "the structured look rounds its measures: temperatures to 0.1 degree" do
    look = %{
      time: @now,
      light: 0.5746756806510838,
      warmth: %{air_c: 18.13460517929985, ground_c: 15.894457893191255},
      channel: %{temp_c: 14.914429726004848},
      hearths: [%{id: "town-hearth", fuel_kg: 8.04}],
      action: %{ref: "m-2", verb: :wait, until: @now + 60},
      away: [%{time: @now}]
    }

    assert %{
             light: 0.57,
             warmth: %{air_c: 18.1, ground_c: 15.9},
             channel: %{temp_c: 14.9},
             hearths: [%{fuel_kg: 8.04}],
             action: %{until: "813 AR, day 220, 09:01"},
             time: "813 AR, day 220, 09:00"
           } = rounded = Report.look(look)

    refute Map.has_key?(rounded, :away)
  end

  test "a planned step shows its target as named until the Mind resolves it" do
    plan = [{:kindle, [target_name: "the kiln-house hearth", params: %{}]}]
    text = Report.text(report(:still_going, plan: plan), @now)
    assert text =~ "Planned after it: kindle the kiln-house hearth."

    assert %{plan: [%{verb: :kindle, target: "the kiln-house hearth"}]} =
             Report.data(report(:still_going, plan: plan), @now)
  end

  test "a percept's data goes out as it is" do
    smell = %Percept{
      kind: :sensed,
      type: :smoke_smelled,
      time: @now,
      summary: "You smell woodsmoke.",
      data: %{own_fire: true}
    }

    assert %{percepts: [%{data: %{own_fire: true}}]} =
             Report.data(report(:done, percepts: [smell]), @now)
  end
end
