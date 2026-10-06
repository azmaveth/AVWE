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

  test "a yielded plan says the routine took the body back, and what is still under way" do
    action = %{ref: "m-1", verb: :go, target: "the-dry-bend"}
    text = Report.text(report(:yielded, action: action), @now)

    assert text =~
             ~r/^Yielded: your routine took the body back while you were away from the keyboard/

    assert text =~ "Under way: go the-dry-bend."
    assert %{status: :yielded} = Report.data(report(:yielded), @now)
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
