defmodule Avwe.Systems.DaylightTest do
  use ExUnit.Case, async: true

  alias Avwe.{Calendar, Event, Region}
  alias Avwe.Systems.Daylight

  defp region_at(hour) do
    Region.new(
      id: {0, 0},
      seed: 1,
      systems: [Daylight],
      time: Calendar.at(813, day: 220, hour: hour)
    )
  end

  test "light is zero at night and highest around midday" do
    assert Daylight.light(0) == 0.0
    assert Daylight.light(6 * 3_600) == 0.0
    assert Daylight.light(23 * 3_600) == 0.0
    assert_in_delta Daylight.light(trunc(12.5 * 3_600)), 1.0, 1.0e-9
  end

  test "the region's light follows the time of day" do
    assert region_at(3) |> Region.advance(1) |> Map.get(:env) |> Map.get(:light) == 0.0
    assert region_at(12) |> Region.advance(1) |> Map.get(:env) |> Map.get(:light) > 0.9
  end

  test "sunrise is stamped with the exact moment" do
    {events, _region} = region_at(4) |> Region.advance(3 * 60) |> Region.drain_events()

    assert [%Event{type: :sunrise, time: time}] = events
    assert time == Calendar.at(813, day: 220, hour: 6)
  end

  test "an hour-long step that passes sunrise still reports it, at the right time" do
    {events, _region} =
      region_at(5) |> Region.advance(2, dt: Calendar.hour()) |> Region.drain_events()

    assert [%Event{type: :sunrise, time: time}] = events
    assert time == Calendar.at(813, day: 220, hour: 6)
  end
end
