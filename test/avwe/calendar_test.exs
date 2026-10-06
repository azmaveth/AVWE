defmodule Avwe.CalendarTest do
  use ExUnit.Case, async: true

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
end
