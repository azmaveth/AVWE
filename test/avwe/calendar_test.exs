defmodule Avwe.CalendarTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.Calendar

  doctest Avwe.Calendar

  test "at/2 and describe/1 round-trip" do
    time = Calendar.at(813, day: 220, hour: 4, minute: 30)
    assert Calendar.describe(time) == %{year: 813, day: 220, hour: 4, minute: 30, second: 0}
  end

  test "the first moment of a year is day 1 at midnight" do
    assert Calendar.describe(Calendar.at(780)) == %{
             year: 780,
             day: 1,
             hour: 0,
             minute: 0,
             second: 0
           }
  end

  test "time_of_day/1 is seconds since midnight" do
    assert Calendar.time_of_day(Calendar.at(813, day: 5, hour: 6)) == 6 * Calendar.hour()
  end

  describe "a calendar is a value" do
    # A station's: a 20-hour day, a year of 300 days, counted in "SC".
    @station %Calendar{hours_per_day: 20, days_per_year: 300, epoch: "SC"}

    test "the Earth's is the default and what the calendar-less functions use" do
      assert Calendar.earth() == %Calendar{hours_per_day: 24, days_per_year: 365, epoch: "AR"}
      assert Calendar.day(Calendar.earth()) == Calendar.day()
      assert Calendar.year(Calendar.earth()) == Calendar.year()
      assert Calendar.format(Calendar.earth(), 12_345) == Calendar.format(12_345)

      assert Calendar.at(Calendar.earth(), 813, day: 220, hour: 4) ==
               Calendar.at(813, day: 220, hour: 4)
    end

    test "a day and a year are as long as the calendar says, a minute and an hour never differ" do
      assert Calendar.day(@station) == 20 * 3_600
      assert Calendar.year(@station) == 300 * 20 * 3_600
      assert Calendar.hour() == 3_600 and Calendar.minute() == 60
    end

    test "at, describe and format agree on a 20-hour day" do
      time = Calendar.at(@station, 12, day: 299, hour: 19, minute: 59)

      assert Calendar.describe(@station, time) == %{
               year: 12,
               day: 299,
               hour: 19,
               minute: 59,
               second: 0
             }

      assert Calendar.format(@station, time) == "12 SC, day 299, 19:59"

      assert Calendar.describe(@station, time + 60) == %{
               year: 12,
               day: 300,
               hour: 0,
               minute: 0,
               second: 0
             }

      assert Calendar.describe(@station, time + 60 + 20 * 3_600) ==
               %{year: 13, day: 1, hour: 0, minute: 0, second: 0}
    end

    test "time_of_day is seconds since the midnight of its own day" do
      assert Calendar.time_of_day(@station, Calendar.at(@station, 3, day: 7, hour: 5)) ==
               5 * 3_600

      assert Calendar.time_of_day(@station, 20 * 3_600 - 1) == 20 * 3_600 - 1
      assert Calendar.time_of_day(@station, 20 * 3_600) == 0
    end

    property "describe and at round-trip, in any calendar" do
      check all hours <- integer(1..48),
                days <- integer(1..400),
                year <- integer(-5..2_000),
                day <- integer(1..400),
                hour <- integer(0..47),
                minute <- integer(0..59) do
        calendar = %Calendar{hours_per_day: hours, days_per_year: days, epoch: "XX"}
        day = min(day, days)
        hour = min(hour, hours - 1)

        time = Calendar.at(calendar, year, day: day, hour: hour, minute: minute)

        assert %{year: ^year, day: ^day, hour: ^hour, minute: ^minute, second: 0} =
                 Calendar.describe(calendar, time)
      end
    end

    test "a region keeps its calendar and hands it to its systems in the tick" do
      defmodule Probe do
        @moduledoc false
        @behaviour Avwe.System

        @impl Avwe.System
        def run(region, tick) do
          {Avwe.Region.put_env(region, :calendar, tick.calendar), []}
        end
      end

      region = Avwe.Region.new(id: {0, 0}, seed: 1, calendar: @station, systems: [Probe])
      assert region.calendar == @station
      assert Avwe.Region.advance(region, 1).env.calendar == @station

      assert Avwe.Region.new(id: {0, 0}, seed: 1).calendar == Calendar.earth()
    end
  end
end
