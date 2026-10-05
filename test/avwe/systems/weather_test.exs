defmodule Avwe.Systems.WeatherTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.{Calendar, Region}
  alias Avwe.Systems.Weather

  @day Calendar.day()
  @hour Calendar.hour()

  describe "the daily curve" do
    test "hits its reference values" do
      for {hour, expected} <- [{4, 13.08}, {12, 23.39}, {15, 25.0}, {19, 16.1}, {22, 14.09}] do
        assert_in_delta Weather.air_c(hour * @hour), expected, 0.01
      end

      assert_in_delta Weather.daily_mean_air_c(), 17.314, 0.001
    end

    test "is continuous at 06:00 and 15:00 and stays within 13 to 25" do
      # Both branches give exactly 13 at the rise and 25 at the peak.
      assert_in_delta Weather.air_c(6 * @hour), 13.0, 1.0e-9
      assert_in_delta Weather.air_c(15 * @hour), 25.0, 1.0e-9

      for join <- [6 * @hour, 15 * @hour] do
        assert_in_delta Weather.air_c(join - 1), Weather.air_c(join), 0.01
        assert_in_delta Weather.air_c(join + 1), Weather.air_c(join), 0.01
      end

      for tod <- 0..(@day - 1)//30 do
        air = Weather.air_c(Calendar.at(813, day: 220) + tod)
        assert air >= 13.0 and air <= 25.0
      end
    end

    test "the sky is ten degrees below the air" do
      assert_in_delta Weather.sky_c(19 * @hour), Weather.air_c(19 * @hour) - 10.0, 1.0e-12
      assert_in_delta Weather.mean_sky_c(0, @day), Weather.daily_mean_air_c() - 10.0, 1.0e-12
    end
  end

  describe "mean_air_c/2" do
    test "over any whole day is the daily mean" do
      for t <- [0, Calendar.at(813, day: 220, hour: 4), Calendar.at(812, day: 200, hour: 15) + 17] do
        assert_in_delta Weather.mean_air_c(t, t + @day), Weather.daily_mean_air_c(), 1.0e-9
      end
    end

    test "agrees with a one-second trapezoid over the day" do
      trapezoid =
        Enum.reduce(0..(@day - 1), 0.0, fn s, acc ->
          acc + (Weather.air_c(s) + Weather.air_c(s + 1)) / 2
        end)

      assert_in_delta trapezoid, Weather.daily_mean_air_c() * @day, 1.0
    end

    # Each window lies in a different segment of the piecewise curve, or spans
    # a join or midnight; a whole day cancels the integral's shape, so only
    # partial windows test it.
    test "agrees with a trapezoid over windows in every segment of the day" do
      midnight = Calendar.at(812, day: 200)

      for {from, to} <- [{2, 5}, {23, 31}, {5, 7}, {9, 12}, {14, 16}, {17, 19}] do
        {t0, t1} = {midnight + from * @hour, midnight + to * @hour}

        trapezoid =
          Enum.reduce(t0..(t1 - 1), 0.0, fn s, acc ->
            acc + (Weather.air_c(s) + Weather.air_c(s + 1)) / 2
          end)

        assert_in_delta Weather.mean_air_c(t0, t1), trapezoid / (t1 - t0), 1.0e-6
      end
    end

    test "over an hour is the mean of the minutes, to a sample's error" do
      t = Calendar.at(812, day: 200, hour: 18)
      minutes = Enum.map(0..59, &Weather.air_c(t + &1 * 60 + 30))
      assert_in_delta Weather.mean_air_c(t, t + @hour), Enum.sum(minutes) / 60, 1.0e-3
    end

    property "adds over adjacent intervals, across a day boundary" do
      check all start <- integer(0..(@day - 1)),
                first <- integer(1..@day),
                second <- integer(1..@day) do
        t0 = Calendar.at(812, day: 200) + start
        t1 = t0 + first
        t2 = t1 + second

        assert_in_delta Weather.mean_air_c(t0, t2) * (t2 - t0),
                        Weather.mean_air_c(t0, t1) * (t1 - t0) +
                          Weather.mean_air_c(t1, t2) * (t2 - t1),
                        1.0e-6
      end
    end
  end

  describe "as a system" do
    test "publishes the air and sky at the start and the end of each step" do
      time = Calendar.at(813, day: 220, hour: 4)
      region = Region.new(id: {0, 0}, seed: 1, systems: [Weather], time: time) |> Region.prepare()

      assert region.env.air_c == Weather.air_c(time)
      assert region.env.sky_c == Weather.sky_c(time)

      stepped = Region.advance(region, 2, dt: @hour)
      assert stepped.env.air_c == Weather.air_c(time + 2 * @hour)
      assert stepped.env.sky_c == Weather.sky_c(time + 2 * @hour)
      assert {[], _region} = Region.drain_events(stepped)
    end
  end
end
