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

  describe "mean_light/2" do
    @day Calendar.day()
    @hour Calendar.hour()
    @midnight Calendar.at(813, day: 220)

    test "over a day, over the noon hour and over the night" do
      assert_in_delta Daylight.mean_light(@midnight, @midnight + @day), 0.34484, 1.0e-4

      assert_in_delta Daylight.mean_light(@midnight + 12 * @hour, @midnight + 13 * @hour),
                      0.99,
                      0.01

      assert Daylight.mean_light(@midnight + 20 * @hour, @midnight + 29 * @hour) == 0.0
    end

    test "the mean of the hourly means is the daily mean" do
      hourly =
        for h <- 0..23,
            do: Daylight.mean_light(@midnight + h * @hour, @midnight + (h + 1) * @hour)

      assert_in_delta Enum.sum(hourly) / 24,
                      Daylight.mean_light(@midnight, @midnight + @day),
                      1.0e-9
    end

    test "agrees with a one-second trapezoid of light/1" do
      trapezoid =
        Enum.reduce(0..(@day - 1), 0.0, fn s, acc ->
          acc + (Daylight.light(s) + Daylight.light(s + 1)) / 2
        end)

      assert_in_delta trapezoid / @day, Daylight.mean_light(@midnight, @midnight + @day), 1.0e-6
    end
  end

  test "an hour-long step that passes sunrise still reports it, at the right time" do
    {events, _region} =
      region_at(5) |> Region.advance(2, dt: Calendar.hour()) |> Region.drain_events()

    assert [%Event{type: :sunrise, time: time}] = events
    assert time == Calendar.at(813, day: 220, hour: 6)
  end
end
